// A local DAP peer only: it never starts or attaches to a program.
import { appendFileSync } from "node:fs";
let buffer = Buffer.alloc(0), sequence = 0;
const [source, log] = process.argv.slice(2);
function send(message) {
    const body = JSON.stringify({ seq: ++sequence, ...message });
    process.stdout.write("Content-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
}
process.stdin.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
        const header = buffer.indexOf("\r\n\r\n");
        if (header < 0) break;
        const length = Number(/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, header).toString())[1]);
        if (buffer.length < header + 4 + length) break;
        const request = JSON.parse(buffer.subarray(header + 4, header + 4 + length).toString());
        buffer = buffer.subarray(header + 4 + length);
        appendFileSync(log, JSON.stringify(request) + "\n");
        let body = {};
        if (request.command === "initialize") body = { supportsConfigurationDoneRequest: true, supportsTerminateRequest: true };
        if (request.command === "threads") body = { threads: [{ id: 1, name: "main" }] };
        if (request.command === "stackTrace") body = { stackFrames: [{ id: 10, name: "main", line: 2, column: 1, source: { path: source } }], totalFrames: 1 };
        if (request.command === "scopes") body = { scopes: [{ name: "Locals", variablesReference: 100, expensive: false },
            { name: "Registers", presentationHint: "registers", variablesReference: 200, expensive: false }] };
        if (request.command === "variables") body = request.arguments.variablesReference === 200
            ? { variables: [{ name: "x0", value: "0x2a", type: "uint64", variablesReference: 0 }] }
            : { variables: [{ name: "answer", value: "42", type: "int", variablesReference: 0 }] };
        send({ type: "response", request_seq: request.seq, command: request.command, success: true, body });
        if (request.command === "initialize") send({ type: "event", event: "initialized" });
        if (request.command === "configurationDone") send({ type: "event", event: "stopped", body: { reason: "entry", threadId: 1, allThreadsStopped: true } });
        if (request.command === "terminate") send({ type: "event", event: "terminated" });
        if (request.command === "disconnect") setTimeout(() => process.exit(0), 20);
    }
});
process.stdin.on("end", () => process.exit(0));
