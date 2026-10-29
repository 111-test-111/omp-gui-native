import assert from 'node:assert/strict';

export async function waitFor(read, message, milliseconds = 15000) {
    const deadline = Date.now() + milliseconds;
    let last;
    while (Date.now() < deadline) {
        try { const value = await read(); if (value) return value; } catch (error) { last = error; }
        await new Promise(resolve => setTimeout(resolve, 75));
    }
    throw new Error(message + (last ? ': ' + last.message : ': timeout'));
}

export class BrowserCDP {
    constructor(socket) {
        this.socket = socket; this.next = 0; this.pending = new Map();
        socket.addEventListener('message', event => {
            const value = JSON.parse(event.data), pending = this.pending.get(value.id);
            if (!pending) return;
            this.pending.delete(value.id); clearTimeout(pending.timer);
            value.error ? pending.reject(new Error(JSON.stringify(value.error))) : pending.resolve(value.result);
        });
        socket.addEventListener('close', () => {
            for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('CDP closed')); }
            this.pending.clear();
        });
    }
    static async connect(url) {
        const socket = new WebSocket(url), client = new BrowserCDP(socket);
        await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, {once:true}); socket.addEventListener('error', reject, {once:true}); });
        return client;
    }
    send(method, params = {}) {
        const id = ++this.next;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('CDP timeout: ' + method)); }, 10000);
            this.pending.set(id, {resolve, reject, timer}); this.socket.send(JSON.stringify({id, method, params}));
        });
    }
    async evaluate(expression) {
        const result = await this.send('Runtime.evaluate', {expression, awaitPromise:true, returnByValue:true});
        assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails)); return result.result.value;
    }
    close() { this.socket.close(); }
}
