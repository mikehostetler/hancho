# Hancho CLI Exit Codes

| Code | Meaning |
|---|---|
| 0 | The command completed successfully. |
| 64 | The command or its arguments are not valid. |
| 65 | Input data or a protocol document is not valid. |
| 66 | A repository, run, or input file was not found. |
| 69 | A required command, adapter, service, or feature is not available. |
| 70 | Hancho had an unexpected internal failure. |
| 73 | Hancho could not create or update a required local file. |
| 74 | Durable data, an artifact, or a database operation failed. |
| 75 | Work stopped, needs a decision, has a conflict, or has an uncertain effect. |
| 76 | A local control or adapter protocol response is invalid. |
| 77 | A local factory identity or permission check failed. |
| 78 | Configuration, workflow, routing, or schema validation failed. |
| 130 | A foreground command stopped after an interrupt. |

Expected command errors do not print an Elixir stack trace. `--debug` enables an unexpected stack trace for diagnosis. JSON errors always contain `schema_version`, `result`, and `message`.
