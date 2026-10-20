%dw 2.0
output application/java
import toPaymentRecord from dw::modules::Payments
---
// Line 1 is the header, so the first data row is line 2.
payload map ((row, index) -> toPaymentRecord(row, index + 2, vars.runId, vars.file.name))
