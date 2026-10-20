%dw 2.0
import isBlank from dw::core::Strings
import try from dw::Runtime

var REQUIRED_COLUMNS = ["payment_reference", "payee_name", "payee_abn", "bsb", "account_number", "amount", "payment_date"]

var ABN_WEIGHTS = [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]

/* ---------------------------------------------------------------------------------------
   File level
   --------------------------------------------------------------------------------------- */

/**
 * Problems that make the whole file unusable, as opposed to a bad row.
 */
fun fileProblems(rows: Any): Array<String> =
    if ((not (rows is Array)) or isEmpty(rows)) ["the file has no payment rows"]
    else do {
        var columns = keysOf(rows[0]) map ($ as String)
        var missing = REQUIRED_COLUMNS filter ((column) -> not (columns contains column))
        ---
        if (isEmpty(missing)) [] else ["missing columns: " ++ (missing joinBy ", ")]
    }

/**
 * payments_20261020.csv + "summary.json" -> payments_20261020.summary.json
 */
fun outputFileName(fileName: String, suffix: String): String =
    (fileName replace /(?i)\.csv$/ with "") ++ "." ++ suffix

/* ---------------------------------------------------------------------------------------
   Row level
   --------------------------------------------------------------------------------------- */

fun text(value: Any): String = trim((value default "") as String)

/**
 * One CSV row to a batch record. Values stay as text until validation has passed.
 */
fun toPaymentRecord(row: Object, lineNumber: Number, runId: String, fileName: String): Object = {
    runId: runId,
    fileName: fileName,
    lineNumber: lineNumber,
    paymentReference: text(row.payment_reference),
    payeeName: text(row.payee_name),
    payeeAbn: text(row.payee_abn) replace /\s/ with "",
    bsb: text(row.bsb),
    accountNumber: text(row.account_number),
    amount: text(row.amount),
    paymentDate: text(row.payment_date),
    description: if (isBlank(row.description)) null else text(row.description)
}

/**
 * ABN check digits: subtract 1 from the first digit, multiply the eleven digits by
 * 10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19 and add them up. The ABN is valid if the total
 * divides by 89.
 */
fun isValidAbn(abn: Any): Boolean = do {
    var digits = if (abn is String) (abn replace /\s/ with "") else ""
    ---
    if (not (digits matches /^[0-9]{11}$/)) false
    else do {
        var values = (0 to 10) map ((position) -> (digits[position] as Number) - (if (position == 0) 1 else 0))
        var total = sum(values map ((value, position) -> value * ABN_WEIGHTS[position]))
        ---
        (total mod 89) == 0
    }
}

/**
 * Six digits, optionally written 000-000.
 */
fun isValidBsb(bsb: Any): Boolean =
    if (bsb is String) (bsb matches /^[0-9]{3}-?[0-9]{3}$/) else false

fun normaliseBsb(bsb: String): String = do {
    var digits = bsb replace "-" with ""
    ---
    digits[0 to 2] ++ "-" ++ digits[3 to 5]
}

fun isValidAccountNumber(accountNumber: Any): Boolean =
    if (accountNumber is String) (accountNumber matches /^[0-9]{6,9}$/) else false

/**
 * Dollars and up to two decimal places, greater than zero. No sign, no thousands separators.
 */
fun isValidAmount(amount: Any): Boolean =
    if (not (amount is String)) false
    else if (not (amount matches /^[0-9]{1,13}(\.[0-9]{1,2})?$/)) false
    else (amount as Number) > 0

fun isValidDate(value: Any): Boolean =
    if (not (value is String)) false
    else if (not (value matches /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) false
    else try(() -> value as Date).success

/**
 * Reason codes for a record, or an empty array if it can be loaded.
 */
fun validationErrors(record: Object): Array<String> =
    (if (isBlank(record.paymentReference) or (sizeOf(record.paymentReference) > 35)) ["INVALID_REFERENCE"] else [])
    ++ (if (isBlank(record.payeeName)) ["MISSING_PAYEE_NAME"] else [])
    ++ (if (not isValidBsb(record.bsb)) ["INVALID_BSB"] else [])
    ++ (if (not isValidAccountNumber(record.accountNumber)) ["INVALID_ACCOUNT_NUMBER"] else [])
    ++ (if (not isValidAmount(record.amount)) ["INVALID_AMOUNT"] else [])
    ++ (if (not isValidAbn(record.payeeAbn)) ["INVALID_ABN"] else [])
    ++ (if (not isValidDate(record.paymentDate)) ["INVALID_PAYMENT_DATE"] else [])

/* ---------------------------------------------------------------------------------------
   Database parameters
   --------------------------------------------------------------------------------------- */

fun toInsertParameters(record: Object): Object = {
    runId: record.runId,
    fileName: record.fileName,
    lineNumber: record.lineNumber,
    paymentReference: record.paymentReference,
    payeeName: record.payeeName,
    payeeAbn: record.payeeAbn,
    bsb: normaliseBsb(record.bsb),
    accountNumber: record.accountNumber,
    amount: record.amount as Number,
    paymentDate: record.paymentDate,
    description: record.description
}

/**
 * Cuts a raw value to its column width, so a malformed row can always be recorded.
 */
fun fit(value: Any, width: Number): String | Null = do {
    var textValue = if (value == null) null else value as String
    ---
    if (textValue == null) null
    else if (sizeOf(textValue) <= width) textValue
    else textValue[0 to width - 1]
}

fun toRejectParameters(record: Object): Object = {
    runId: record.runId,
    fileName: record.fileName,
    lineNumber: record.lineNumber,
    paymentReference: fit(record.paymentReference, 35),
    payeeName: fit(record.payeeName, 140),
    payeeAbn: fit(record.payeeAbn, 20),
    bsb: fit(record.bsb, 10),
    accountNumber: fit(record.accountNumber, 20),
    amount: fit(record.amount, 20),
    paymentDate: fit(record.paymentDate, 20),
    reasons: fit((record.reasons default []) joinBy "|", 200)
}

/* ---------------------------------------------------------------------------------------
   Run outcome
   --------------------------------------------------------------------------------------- */

var REJECTS_COLUMNS = ["line_number", "payment_reference", "payee_name", "payee_abn", "bsb",
                       "account_number", "amount", "payment_date", "reasons"]

fun toRejectsCsvRow(row: Object): Object = {
    line_number: row.line_number,
    payment_reference: row.payment_reference,
    payee_name: row.payee_name,
    payee_abn: row.payee_abn,
    bsb: row.bsb,
    account_number: row.account_number,
    amount: row.amount,
    payment_date: row.payment_date,
    reasons: row.reasons
}

/**
 * The rejects file is always written, so the sender always gets a pair of files back.
 * With nothing rejected it holds just the header.
 */
fun rejectsCsv(rows: Array): String =
    if (isEmpty(rows)) (REJECTS_COLUMNS joinBy ",") ++ "\n"
    else write(rows map toRejectsCsvRow($), "application/csv", { header: true }) as String

fun runStatus(failedRecords: Number, rejectedRecords: Number): String =
    if (failedRecords > 0) "COMPLETED_WITH_ERRORS"
    else if (rejectedRecords > 0) "COMPLETED_WITH_REJECTS"
    else "COMPLETED"

fun summary(run: Object, job: Object, loaded: Object, rejectedRecords: Number, completedAt: String): Object = {
    runId: run.runId,
    fileName: run.fileName,
    archivedAs: run.archivedAs,
    receivedAt: run.receivedAt,
    completedAt: completedAt,
    totalRecords: job.totalRecords,
    loadedRecords: loaded.loaded_count as Number,
    loadedAmount: loaded.loaded_amount as Number,
    rejectedRecords: rejectedRecords,
    failedRecords: job.failedRecords,
    elapsedMs: job.elapsedMs,
    status: runStatus(job.failedRecords as Number, rejectedRecords)
}
