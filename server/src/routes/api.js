const express = require('express');
const router = express.Router();
const tabletApi = require('../controllers/tabletApiController');

router.post('/tablets/register', tabletApi.register);
router.post('/tablets/heartbeat', tabletApi.heartbeat);
router.get('/tablets/:deviceId/config', tabletApi.getConfig);

module.exports = router;
