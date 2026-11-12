// Ephemeral signaling-only server for native protocol integration tests.
import { createApp } from '../server.js';
const app = createApp({});
app.server.listen(0, '127.0.0.1', () => console.log(`http://127.0.0.1:${app.server.address().port}`));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => app.close().then(() => process.exit(0)));
