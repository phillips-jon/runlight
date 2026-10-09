<?php

// Copy this file to config.php in the project folder (the one holding vendor/), outside the web root, with
// cp vendor/runlight/runlight/config.example.php config.php
// Environment variables with the same names win over what is here. Leave out what you do not need.
// Docs: https://runlight.sh/docs/php/#settings

return [
    // The dashboard's public address. Short links never take it over, and emails link to it.
    'RUNLIGHT_URL' => 'https://stats.example.com',

    // SQLite in the data folder by default. Set a URL to use Postgres, MySQL, or MariaDB instead.
    // 'DATABASE_URL' => 'mysql://runlight:password@localhost:3306/runlight',

    // The SQLite file, the secret, the setup link, and location data. Relative to the project folder.
    // 'DATA_DIR' => 'runlight-data',

    // Signs sign-ins and encrypts saved keys. Made and kept in the data folder when not set here.
    // 'RUNLIGHT_SECRET' => '',

    // A bearer token for scripts. When set, the first account is made with it instead of the setup link.
    // 'RUNLIGHT_TOKEN' => '',

    // "false" when nothing sits in front of the web server, or the one header your proxy sets.
    // 'TRUST_PROXY' => 'false',

    // city (the default), country, off, or the path to an MMDB file of your own.
    // 'RUNLIGHT_GEO' => 'country',

    // Lets a scheduler run the check over HTTP when it cannot run the cron command.
    // 'CRON_SECRET' => '',
];
