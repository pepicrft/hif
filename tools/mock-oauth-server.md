# Mock OAuth Server for Testing

## Quick Test with GitHub

The easiest way to test is with GitHub's device flow:

1. Create an OAuth app: https://github.com/settings/developers
   - Click "New OAuth App"
   - Homepage URL: `http://localhost`  
   - Authorization callback URL: `http://localhost`
   - Note your Client ID

2. Update your config to use GitHub:
```bash
mkdir -p ~/.hif
cat > ~/.hif/config <<EOF
{
  "forge_url": "https://github.com/login",
  "client_id": "YOUR_CLIENT_ID_HERE"
}
EOF
```

3. Test the flow:
```bash
./zig-out/bin/hif auth login
```

## Simple Mock Server (Node.js)

For completely local testing, here's a minimal mock server:

```javascript
// mock-oauth.js
const http = require('http');

const devices = new Map();

const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  
  if (req.url === '/oauth/device' && req.method === 'POST') {
    const device_code = Math.random().toString(36).substring(7);
    const user_code = Math.random().toString(36).substring(2, 8).toUpperCase();
    
    devices.set(device_code, { authorized: false, user_code });
    
    res.writeHead(200);
    res.end(JSON.stringify({
      device_code,
      user_code,
      verification_uri: `http://localhost:3000/verify`,
      interval: 2
    }));
  } 
  else if (req.url === '/oauth/token' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      const params = new URLSearchParams(body);
      const device_code = params.get('device_code');
      const device = devices.get(device_code);
      
      if (!device) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: 'invalid_grant' }));
        return;
      }
      
      if (!device.authorized) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: 'authorization_pending' }));
        return;
      }
      
      res.writeHead(200);
      res.end(JSON.stringify({
        access_token: 'mock_token_' + Date.now(),
        refresh_token: 'mock_refresh_' + Date.now(),
        expires_in: 3600
      }));
    });
  }
  else if (req.url.startsWith('/verify')) {
    // In real use, show a web page for manual authorization
    // For testing, auto-authorize after 5 seconds
    setTimeout(() => {
      devices.forEach((device, code) => {
        device.authorized = true;
      });
    }, 5000);
    
    res.writeHead(200, {'Content-Type': 'text/html'});
    res.end('<h1>Auto-authorizing in 5 seconds...</h1>');
  }
});

server.listen(3000, () => {
  console.log('Mock OAuth server running on http://localhost:3000');
  console.log('Update ~/.hif/config to use: http://localhost:3000');
});
```

Run it:
```bash
node mock-oauth.js
```

Update config:
```bash
cat > ~/.hif/config <<EOF
{
  "forge_url": "http://localhost:3000"
}
EOF
```

Test:
```bash
./zig-out/bin/hif auth login
```
