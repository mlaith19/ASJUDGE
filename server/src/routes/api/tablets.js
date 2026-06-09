/**
 * Tablet API routes.
 * Live tablet communication (register, heartbeat, config, commands) is WebSocket-only.
 * These HTTP endpoints are intentionally removed; use Socket.IO namespaces /tablet and /admin.
 */
const express = require('express');
const router = express.Router();

// No HTTP routes for register, heartbeat, config, or action-completed.
// Tablets: connect to /tablet namespace, emit tablet_register, heartbeat; listen for tablet_command; emit command_completed.
// Admin: connect to /admin namespace; listen for dashboard_state, tablet_connected, tablet_heartbeat, tablet_offline, command_completed.

module.exports = router;
