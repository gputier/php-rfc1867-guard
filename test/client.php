<?php
// Functional test client, written for PHP 5.4 and later.
//
//   php client.php http|fcgi <host> <port> guarded|unguarded
//
// Sends a multipart POST with PHP_SESSION_UPLOAD_PROGRESS, a session cookie and a 200 KB file,
// then a GET with the same cookie. Exit code 0 when the response matches the expectation.

if ($argc !== 5) {
    fwrite(STDERR, "usage: client.php http|fcgi host port guarded|unguarded\n");
    exit(2);
}
list(, $mode, $host, $port, $expect) = $argv;

$sid = 'guardtest' . str_repeat('0123456789abcdef', 2);
$progressName = 'guard-test';
$blob = '';
for ($i = 0; strlen($blob) < 200 * 1024; $i++) {
    $blob .= md5($i, true);
}
$blob = substr($blob, 0, 200 * 1024);

$boundary = '----rfc1867guard' . md5('boundary');
$body = "--$boundary\r\n"
    . "Content-Disposition: form-data; name=\"PHP_SESSION_UPLOAD_PROGRESS\"\r\n\r\n$progressName\r\n"
    . "--$boundary\r\n"
    . "Content-Disposition: form-data; name=\"f\"; filename=\"blob.bin\"\r\n"
    . "Content-Type: application/octet-stream\r\n\r\n$blob\r\n"
    . "--$boundary--\r\n";

function connect($host, $port)
{
    for ($try = 0; $try < 100; $try++) {
        $fp = @fsockopen($host, (int) $port, $errno, $errstr, 5);
        if ($fp) {
            return $fp;
        }
        usleep(200000);
    }
    fwrite(STDERR, "cannot connect to $host:$port\n");
    exit(2);
}

function http_request($host, $port, $method, $uri, $headers, $body)
{
    $fp = connect($host, $port);
    $req = "$method $uri HTTP/1.0\r\nHost: $host\r\n" . $headers
        . 'Content-Length: ' . strlen($body) . "\r\n\r\n" . $body;
    fwrite($fp, $req);
    $raw = '';
    while (!feof($fp)) {
        $raw .= fread($fp, 8192);
    }
    fclose($fp);
    $pos = strpos($raw, "\r\n\r\n");
    return $pos === false ? $raw : substr($raw, $pos + 4);
}

function fcgi_record($type, $content)
{
    return pack('CCnnCC', 1, $type, 1, strlen($content), 0, 0) . $content;
}

function fcgi_length($n)
{
    return $n < 128 ? chr($n) : pack('N', $n | 0x80000000);
}

function fcgi_request($host, $port, $method, $uri, $headers, $body)
{
    $params = array(
        'GATEWAY_INTERFACE' => 'CGI/1.1',
        'REQUEST_METHOD' => $method,
        'SCRIPT_FILENAME' => '/test/www/index.php',
        'SCRIPT_NAME' => '/index.php',
        'REQUEST_URI' => $uri,
        'QUERY_STRING' => (string) parse_url($uri, PHP_URL_QUERY),
        'SERVER_PROTOCOL' => 'HTTP/1.0',
        'SERVER_NAME' => $host,
        'SERVER_PORT' => (string) $port,
        'CONTENT_LENGTH' => (string) strlen($body),
    );
    foreach (explode("\r\n", trim($headers)) as $line) {
        list($name, $value) = array_map('trim', explode(':', $line, 2));
        if (strtolower($name) === 'content-type') {
            $params['CONTENT_TYPE'] = $value;
        } else {
            $params['HTTP_' . strtoupper(str_replace('-', '_', $name))] = $value;
        }
    }
    $encoded = '';
    foreach ($params as $k => $v) {
        $encoded .= fcgi_length(strlen($k)) . fcgi_length(strlen($v)) . $k . $v;
    }

    $out = fcgi_record(1, pack('nCCCCCC', 1, 0, 0, 0, 0, 0, 0))
        . fcgi_record(4, $encoded) . fcgi_record(4, '');
    for ($off = 0; $off < strlen($body); $off += 65000) {
        $out .= fcgi_record(5, substr($body, $off, 65000));
    }
    $out .= fcgi_record(5, '');

    $fp = connect($host, $port);
    fwrite($fp, $out);
    $stdout = '';
    while (($head = fread($fp, 8)) !== false && strlen($head) === 8) {
        $h = unpack('Cversion/Ctype/nid/nlen/Cpad/Creserved', $head);
        $content = '';
        while (strlen($content) < $h['len']) {
            $content .= fread($fp, $h['len'] - strlen($content));
        }
        if ($h['pad'] > 0) {
            fread($fp, $h['pad']);
        }
        if ($h['type'] === 6) {
            $stdout .= $content;
        } elseif ($h['type'] === 3) {
            break;
        }
    }
    fclose($fp);
    $pos = strpos($stdout, "\r\n\r\n");
    return $pos === false ? $stdout : substr($stdout, $pos + 4);
}

function parse_lines($text)
{
    $result = array();
    foreach (explode("\n", trim($text)) as $line) {
        if (strpos($line, '=') !== false) {
            list($k, $v) = explode('=', $line, 2);
            $result[$k] = $v;
        }
    }
    return $result;
}

$send = $mode === 'fcgi' ? 'fcgi_request' : 'http_request';
$cookie = "Cookie: PHPSESSID=$sid\r\n";

$post = parse_lines($send($host, $port, 'POST', '/index.php',
    $cookie . "Content-Type: multipart/form-data; boundary=$boundary\r\n", $body));
$get = parse_lines($send($host, $port, 'GET', '/index.php?read=1', $cookie, ''));

$progressKey = 'upload_progress_' . $progressName;
$keys = isset($post['progress_keys']) && $post['progress_keys'] !== '' ? explode(',', $post['progress_keys']) : array();
$progressPresent = in_array($progressKey, $keys, true);

$checks = array(
    'file received intact' => isset($post['file_size'], $post['file_md5'])
        && (int) $post['file_size'] === strlen($blob) && $post['file_md5'] === md5($blob),
    'session works' => isset($post['guard_active']) && isset($get['probe']) && $get['probe'] === 'ok',
);
if ($expect === 'guarded') {
    $checks['progress key absent'] = !$progressPresent;
    $checks['rfc1867_guard_status()[active]'] = isset($post['guard_active']) && $post['guard_active'] === '1';
} else {
    $checks['progress key present'] = $progressPresent;
    $checks['guard absent'] = isset($post['guard_active']) && $post['guard_active'] === 'absent';
}

$failed = 0;
foreach ($checks as $name => $ok) {
    echo ($ok ? 'ok   ' : 'FAIL ') . $name . "\n";
    $failed += $ok ? 0 : 1;
}
if ($failed) {
    echo "raw POST: " . format_pairs($post) . "\n";
}
exit($failed ? 1 : 0);

function format_pairs($data)
{
    $parts = array();
    foreach ($data as $k => $v) {
        $parts[] = "$k=$v";
    }
    return implode(' ', $parts);
}
