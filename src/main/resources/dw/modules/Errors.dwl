%dw 2.0

/**
 * "NAMESPACE:IDENTIFIER" for logs.
 */
fun errorTypeName(err: Any): String =
    if (err == null) "UNKNOWN"
    else (err.errorType.namespace default "UNKNOWN") ++ ":" ++ (err.errorType.identifier default "UNKNOWN")
