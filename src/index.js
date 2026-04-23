'use strict';

const net = require('net');
const { SocksClient } = require('socks');
const path = require('path');

require('dotenv').config({ path: path.join(__dirname, '../.env') });

// ─── Config ─────────────────────────────────────────────────────────────────
const LISTEN_PORT    = parseInt(process.env.LISTEN_PORT)   || 1080;
const LISTEN_HOST    = process.env.LISTEN_HOST             || '0.0.0.0';
const UPSTREAM_HOST  = process.env.UPSTREAM_HOST;
const UPSTREAM_PORT  = parseInt(process.env.UPSTREAM_PORT);
const UPSTREAM_USER  = process.env.UPSTREAM_USER           || '';
const UPSTREAM_PASS  = process.env.UPSTREAM_PASS           || '';
const CONN_TIMEOUT   = parseInt(process.env.CONN_TIMEOUT)  || 30000;

if (!UPSTREAM_HOST || !UPSTREAM_PORT) {
  console.error('[FATAL] UPSTREAM_HOST and UPSTREAM_PORT must be set in .env');
  process.exit(1);
}

// ─── SOCKS5 Protocol Constants ───────────────────────────────────────────────
const SOCKS5_VER          = 0x05;
const METHOD_NO_AUTH      = 0x00;
const METHOD_NO_ACCEPT    = 0xff;
const CMD_CONNECT         = 0x01;
const ATYP_IPV4           = 0x01;
const ATYP_DOMAIN         = 0x03;
const ATYP_IPV6           = 0x04;
const REP_SUCCESS         = 0x00;
const REP_GENERAL_FAILURE = 0x01;
const REP_CMD_NOT_SUPP    = 0x07;

// ─── SOCKS5 Session ──────────────────────────────────────────────────────────
class SOCKS5Session {
  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.state  = 'GREETING';

    this._onData  = (chunk) => this._feed(chunk);
    this._onError = (err)   => {
      if (err.code !== 'ECONNRESET' && err.code !== 'EPIPE') {
        console.error(`[WARN] client socket error: ${err.message}`);
      }
      this.socket.destroy();
    };

    socket.on('data',  this._onData);
    socket.on('error', this._onError);
    socket.once('close', () => socket.destroy());
  }

  // Accumulate data and drive the state machine
  _feed(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    this._process();
  }

  _process() {
    if      (this.state === 'GREETING') this._handleGreeting();
    else if (this.state === 'REQUEST')  this._handleRequest();
  }

  // ── Step 1: SOCKS5 greeting (version + method negotiation) ──────────────
  _handleGreeting() {
    if (this.buffer.length < 2) return;

    if (this.buffer[0] !== SOCKS5_VER) {
      this.socket.destroy();
      return;
    }

    const nmethods = this.buffer[1];
    if (this.buffer.length < 2 + nmethods) return;

    const methods = Array.from(this.buffer.slice(2, 2 + nmethods));
    this.buffer = this.buffer.slice(2 + nmethods);

    if (methods.includes(METHOD_NO_AUTH)) {
      // We accept no-auth (client-to-wrapper leg is on trusted local network)
      this.socket.write(Buffer.from([SOCKS5_VER, METHOD_NO_AUTH]));
      this.state = 'REQUEST';
      this._process(); // may already have request data buffered
    } else {
      this.socket.write(Buffer.from([SOCKS5_VER, METHOD_NO_ACCEPT]));
      this.socket.end();
    }
  }

  // ── Step 2: SOCKS5 CONNECT request ──────────────────────────────────────
  _handleRequest() {
    // Minimum header: VER CMD RSV ATYP = 4 bytes
    if (this.buffer.length < 4) return;

    if (this.buffer[0] !== SOCKS5_VER) {
      this.socket.destroy();
      return;
    }

    const cmd  = this.buffer[1];
    const atyp = this.buffer[3];

    let host, port, consumed;

    if (atyp === ATYP_IPV4) {
      consumed = 10; // 4 + 4 + 2
      if (this.buffer.length < consumed) return;
      host = `${this.buffer[4]}.${this.buffer[5]}.${this.buffer[6]}.${this.buffer[7]}`;
      port = this.buffer.readUInt16BE(8);

    } else if (atyp === ATYP_DOMAIN) {
      if (this.buffer.length < 5) return;
      const dlen = this.buffer[4];
      consumed = 5 + dlen + 2;
      if (this.buffer.length < consumed) return;
      host = this.buffer.slice(5, 5 + dlen).toString('utf8');
      port = this.buffer.readUInt16BE(5 + dlen);

    } else if (atyp === ATYP_IPV6) {
      consumed = 22; // 4 + 16 + 2
      if (this.buffer.length < consumed) return;
      const parts = [];
      for (let i = 0; i < 8; i++) {
        parts.push(this.buffer.readUInt16BE(4 + i * 2).toString(16));
      }
      host = parts.join(':');
      port = this.buffer.readUInt16BE(20);

    } else {
      this._reply(REP_GENERAL_FAILURE);
      this.socket.end();
      return;
    }

    // Consume the request bytes; anything after is payload for the tunnel
    this.buffer = this.buffer.slice(consumed);

    if (cmd !== CMD_CONNECT) {
      this._reply(REP_CMD_NOT_SUPP);
      this.socket.end();
      return;
    }

    this.state = 'CONNECTING';
    this._connect(host, port);
  }

  // ── Step 3: Tunnel via upstream SOCKS5 ───────────────────────────────────
  async _connect(host, port) {
    const proxyOpts = {
      proxy: {
        host: UPSTREAM_HOST,
        port: UPSTREAM_PORT,
        type: 5,
        ...(UPSTREAM_USER && UPSTREAM_PASS
          ? { userId: UPSTREAM_USER, password: UPSTREAM_PASS }
          : {}),
      },
      command: 'connect',
      destination: { host, port },
      timeout: CONN_TIMEOUT,
    };

    let upstream;
    try {
      ({ socket: upstream } = await SocksClient.createConnection(proxyOpts));
    } catch (err) {
      console.error(`[WARN] upstream connect ${host}:${port} → ${err.message}`);
      this._reply(REP_GENERAL_FAILURE);
      this.socket.end();
      return;
    }

    // Tell client the tunnel is open
    this._reply(REP_SUCCESS);
    this.state = 'CONNECTED';

    // Remove our data/error listeners – pipe takes over from here
    this.socket.removeListener('data',  this._onData);
    this.socket.removeListener('error', this._onError);

    // Flush any bytes that arrived after the CONNECT header
    if (this.buffer.length > 0) {
      upstream.write(this.buffer);
      this.buffer = Buffer.alloc(0);
    }

    // Bidirectional pipe
    this.socket.pipe(upstream);
    upstream.pipe(this.socket);

    this.socket.on('error', () => upstream.destroy());
    upstream.on('error',    () => this.socket.destroy());
    this.socket.on('close', () => upstream.destroy());
    upstream.on('close',    () => this.socket.destroy());

    console.log(`[INFO] tunnel ${host}:${port} via ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  }

  // Helper: send a SOCKS5 reply with BND.ADDR = 0.0.0.0 / BND.PORT = 0
  _reply(rep) {
    const buf = Buffer.alloc(10);
    buf[0] = SOCKS5_VER;
    buf[1] = rep;
    buf[2] = 0x00;       // RSV
    buf[3] = ATYP_IPV4;  // BND.ADDR type
    // bytes 4-7 = 0.0.0.0, bytes 8-9 = 0 (already zeroed)
    this.socket.write(buf);
  }
}

// ─── Server ──────────────────────────────────────────────────────────────────
const server = net.createServer((socket) => {
  socket.setKeepAlive(true, 60000);
  socket.setNoDelay(true);
  new SOCKS5Session(socket);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`[INFO] SOCKS5 proxy  : ${LISTEN_HOST}:${LISTEN_PORT}`);
  console.log(`[INFO] Upstream proxy: socks5://${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  console.log('[INFO] Ready to accept connections.');
});

server.on('error', (err) => {
  console.error(`[FATAL] ${err.message}`);
  process.exit(1);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT',  () => server.close(() => process.exit(0)));
