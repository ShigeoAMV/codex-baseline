Use only native Windows PowerShell terminal commands to inspect this workspace
and create `result.json` in the workspace root. Do not use a file-editing tool.
The file must contain exactly these JSON properties:

- `route`: the relative path of the TypeScript file containing the exported port
- `port`: the exported integer
- `filename`: the leaf name of the text file under `data`
- `literal`: the complete text after `literal: ` in that file

Preserve every starter file byte-for-byte. Do not add any other file. Complete
the inspection and result without `cmd /c` or a nested PowerShell `-Command`
string.
