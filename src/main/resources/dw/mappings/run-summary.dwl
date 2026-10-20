%dw 2.0
output application/java
import summary from dw::modules::Payments
---
summary(
    vars.run,
    vars.jobResult,
    vars.loaded[0],
    sizeOf(vars.rejects),
    now() as String { format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXX" }
)
