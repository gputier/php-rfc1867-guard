<?php
// Probe endpoint for the functional test. Plain "key=value" lines, no json extension needed.
session_start();
header('Content-Type: text/plain');

if (isset($_GET['read'])) {
    echo 'probe=', isset($_SESSION['probe']) ? $_SESSION['probe'] : 'none', "\n";
    exit;
}

$keys = array();
foreach ($_SESSION as $key => $value) {
    if (strpos($key, 'upload_progress_') === 0) {
        $keys[] = $key;
    }
}
$_SESSION['probe'] = 'ok';

echo 'progress_keys=', implode(',', $keys), "\n";
if (isset($_FILES['f']) && $_FILES['f']['error'] === 0) {
    echo 'file_size=', $_FILES['f']['size'], "\n";
    echo 'file_md5=', md5_file($_FILES['f']['tmp_name']), "\n";
}
if (function_exists('rfc1867_guard_status')) {
    $status = rfc1867_guard_status();
    $names = array_keys($status);
    sort($names);
    echo 'guard_active=', $status['active'] ? '1' : '0', "\n";
    echo 'status_keys=', implode(',', $names), "\n";
    echo 'status_types=', gettype($status['active']), ',', gettype($status['detached_at_startup']), ',',
        gettype($status['foreign_hooks_cleared']), ',', gettype($status['version']), "\n";
    echo 'status_detached_at_startup=', $status['detached_at_startup'] ? '1' : '0', "\n";
    echo 'status_foreign_hooks_cleared=', $status['foreign_hooks_cleared'], "\n";
    echo 'status_version=', $status['version'], "\n";
} else {
    echo "guard_active=absent\n";
}
