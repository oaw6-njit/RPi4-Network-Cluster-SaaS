<?php
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $name = htmlspecialchars($_POST["name"]);
    echo "Hello, " . $name . "! Your PHP test is working.";
} else {
    echo "No data was received.";
}
?>
