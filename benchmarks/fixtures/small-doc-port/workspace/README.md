# Status service

Start the service on a custom port:

```sh
SERVICE_PORT=4100 node server.js
```

When no port is configured, the server listens on port 8080.

After startup, check it with `curl http://127.0.0.1:4100/health`.
