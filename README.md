# payments-file-batch

File and batch integration for a finance payments feed. A sender drops CSV payment files on
an MFT/SFTP server; this application picks them up on a schedule, validates every row, loads
the good ones into the finance database in blocks, and writes a summary and a rejects file
back to the sender's outbound folder.

Mule 4.9 LTS, Java 17, SFTP and Database connectors, Mule Batch, PostgreSQL.

## File layout

```
payment_reference,payee_name,payee_abn,bsb,account_number,amount,payment_date,description
INV-20261020-001,Red Dirt Haulage Pty Ltd,53 900 000 001,062-000,12345678,1520.00,2026-10-21,October haulage
INV-20261020-002,Spinifex Catering,34900000002,083170,987654321,2650.25,2026-10-21,Camp catering
```

`description` is optional; the other columns are required. A complete example with good and
bad rows is `src/test/resources/fixtures/files/payments_20261020.csv`.

## Flow of a file

```
/inbound/payments_20261020.csv
  -> claim the file name in the watermark store (fails if seen before -> /duplicates)
  -> parse CSV, check the header (unusable file -> /error, name released)
  -> move to /archive/<runId>_payments_20261020.csv
  -> Batch Job (instance id = runId)
       validate-payment       rejectReasons per record, never throws
       load-payment           good records, Batch Aggregator -> bulk insert into payment
       record-reject          bad records, Batch Aggregator -> bulk insert into payment_reject
       capture-load-failure   records whose block failed to insert -> payment_reject (LOAD_FAILED)
       On Complete            summary + rejects CSV to /outbound, watermark updated
```

**Scheduling.** `payments-file-pickup` is an SFTP listener with a fixed-frequency scheduling
strategy, matching `*.csv` case-insensitively. `timeBetweenSizeCheck` makes it wait until a
file has stopped growing, so a file still being uploaded is never read. It runs on the
primary node only.

**Watermark.** `processed-files-store` is a persistent object store of file names. Pickup
claims the name with `os:store ... failIfPresent="true"`, which is atomic, so a resent file or
two workers polling at once cannot load the same file twice; `OS:KEY_ALREADY_EXISTS` becomes
`PAYMENTS:DUPLICATE_FILE` and the file is moved to `/duplicates`. The entry starts as
`LOADING` and On Complete overwrites it with the run's final status. If a file fails before
loading starts, the name is released so a corrected file with the same name can be sent, but
only if this run claimed it: a claim belonging to an earlier run is never removed. To force a
reprocess, delete the file name's key from the store.

**Validation.** `dw/modules/Payments.dwl` holds the rules, each returning a reason code:

| Rule                                                             | Reason                   |
|------------------------------------------------------------------|--------------------------|
| reference present, at most 35 characters                         | `INVALID_REFERENCE`      |
| payee name present                                               | `MISSING_PAYEE_NAME`     |
| BSB is six digits, optionally `000-000`                          | `INVALID_BSB`            |
| account number is 6 to 9 digits                                  | `INVALID_ACCOUNT_NUMBER` |
| amount greater than zero, at most two decimal places             | `INVALID_AMOUNT`         |
| ABN check digits (below)                                         | `INVALID_ABN`            |
| payment date is a real `yyyy-MM-dd` date                         | `INVALID_PAYMENT_DATE`   |

The ABN check is the ATO algorithm: subtract 1 from the first digit, multiply the eleven
digits by 10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, add them up, and the total must divide by 89.

**Loading.** Validation never throws; it sets a record variable, and the next steps choose
records with `acceptExpression`. Each loading step ends in a Batch Aggregator of
`batch.commitSize` records feeding a `db:bulk-insert`, so the database sees one batched
statement per block rather than one insert per row (`reWriteBatchedInserts=true` on the JDBC
URL helps further). `payment` has a unique key on `(run_id, line_number)`, so a retried block
cannot insert a line twice. `maxFailedRecords="-1"` keeps the job going when a block fails; the
`capture-load-failure` step (`acceptPolicy="ONLY_FAILURES"`) records those rows as
`LOAD_FAILED` so they appear in the rejects file instead of disappearing.

**On Complete.** The job runs asynchronously and On Complete only receives the
`BatchJobResult`, so pickup stores the file details in `batch-run-store` under the run id.
`write-run-outcome` reads them back, takes the loaded count and control total from the
`payment` table, reads the rejected rows, and writes to `/outbound`:

- `payments_20261020.summary.json`: run id, file name, archive path, total, loaded, rejected
  and failed counts, the loaded amount, timings and a status (`COMPLETED`,
  `COMPLETED_WITH_REJECTS` or `COMPLETED_WITH_ERRORS`);
- `payments_20261020.rejects.csv`: the original values, line number and the reasons
  separated by `|` for every rejected row. It is written on every run, header only when
  nothing was rejected, so the sender always gets the same pair of files back.

**Errors and correlation.** `common/error-handling.xml` holds `file-pickup-error-handler`,
which decides between `/duplicates` and `/error` and handles the watermark release. Moving
a file aside is best effort; if SFTP is down the file stays in `/inbound` for the next poll.
Pickup runs inside `tracing:with-correlation-id` with the run id and adds the file name to the
logging context; every log line from the batch and On Complete includes the run id.

## Project layout

```
src/main/mule/
  global.xml                 properties, secure properties, SFTP, database, object stores
  payments-pickup.xml        scheduled SFTP listener, watermark claim, parse, archive
  payments-batch.xml         the Batch Job
  payments-outcome.xml       On Complete: summary, rejects file, watermark update
  common/error-handling.xml  file-pickup-error-handler, quarantine-file, release-file-name
src/main/resources/
  config/                    config-<env>.yaml and secure-config-<env>.yaml for local, dev and test
  dw/modules/                Payments (rules, mappings, summary), Errors
  dw/mappings/               csv-to-payment-records, run-summary
db/schema.sql                payment and payment_reject tables
src/test/munit/              MUnit suites
src/test/resources/fixtures/ payment files and database rows
```

## Running locally

1. Create the `finance` database with a `payments_loader` login and run `db/schema.sql`.
2. Run an SFTP server on port 2222 with `/inbound`, `/outbound`, `/archive`, `/error` and
   `/duplicates`, a `payments-feed` user with your public key, and put the private key and a
   `known_hosts` entry where `sftp.identityFile` and `sftp.knownHostsFile` point.
3. Encrypt the key passphrase and the database password with the Secure Properties Tool and
   your own 16-character key, and put them in `src/main/resources/config/secure-config-local.yaml`.
4. Run from Anypoint Studio with `-Dmule.env=local -Dmule.key=<key>`, then upload a CSV to
   `/inbound`.

## Tests

- `payments-run-test-suite`: a whole run from pickup to On Complete. The batch job is
  asynchronous, and an assertion inside a step would only fail that record, so spies copy
  what the bulk inserts and file writes receive onto MUnit queues, and the test asserts on
  them after On Complete has finished: which lines were loaded and rejected and why, the
  summary counts and control total, the rejects file, the final watermark status and the
  cleaned-up run context.
- `payments-pickup-test-suite`: a repeated file name goes to `/duplicates` and leaves the
  earlier watermark alone; a file with the wrong columns goes to `/error` and releases its
  name; an archive failure releases the name and starts no job.
- `payments-rules-test-suite`: ABN, BSB, amount, date and file-level rules, reject column
  widths, the header-only rejects file and output file names.

SFTP and database operations are mocked by `doc:name`. Run the suites from Studio or with
`mvn clean test`; Batch is an Enterprise feature, so the command-line run needs credentials
for the MuleSoft EE repository in `settings.xml`.
