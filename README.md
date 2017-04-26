# Five9-run-report-via-API

Script uses Five9 Configuration Web Services API to generate a report in CSV and upload it to an SFTP server.

The way it works is you need to have a previously created report (such as a Call Log or Agent Statistics) in Five9 Dashboard & Reports interface. In the configuration file "config.txt" you specify your Five9 username, password, folder with report and report name as well as a period for which you would like to run a report. Then you schedule a script to run e.g. daily or hourly to send the generated reports to your SFTP server.

You can definitely use Five9 Dashboard & Reports to schedule the same report via simple user interface however it's limited. That's why this repository exists - it's good as a starting point to many projects to implement various customizations, e.g. to send a report to different services (e.g. Amazon S3) or to modify file name (include date and time) or to change report headers (use custom column names), etc.

Feel free to fork it and modify for your own needs.
