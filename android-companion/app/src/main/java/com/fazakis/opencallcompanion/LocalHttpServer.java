package com.fazakis.opencallcompanion;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

final class LocalHttpServer {
    static final int PORT = 9096;
    private final Context context;
    private final DataProvider provider;
    private final SharedPreferences prefs;
    private ServerSocket serverSocket;
    private Thread thread;
    private volatile boolean running = false;

    LocalHttpServer(Context context) {
        this.context = context.getApplicationContext();
        this.provider = new DataProvider(context);
        this.prefs = context.getSharedPreferences("companion", Context.MODE_PRIVATE);
        ensureToken();
    }

    synchronized void start() {
        if (running) return;
        running = true;
        thread = new Thread(this::loop, "OpenCallCompanionHttp");
        thread.start();
    }

    synchronized void stop() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (Exception ignored) {}
        serverSocket = null;
    }

    boolean isRunning() { return running; }

    String token() { return ensureToken(); }

    String resetToken() {
        String token = randomToken();
        prefs.edit().putString("token", token).apply();
        return token;
    }

    String localUrl() {
        String ip = firstIPv4();
        return ip == null ? "http://PHONE-IP:" + PORT : "http://" + ip + ":" + PORT;
    }

    private void loop() {
        try (ServerSocket ss = new ServerSocket(PORT, 50, InetAddress.getByName("0.0.0.0"))) {
            serverSocket = ss;
            while (running) {
                Socket socket = ss.accept();
                new Thread(() -> handle(socket), "OpenCallCompanionClient").start();
            }
        } catch (Exception e) {
            running = false;
        }
    }

    private void handle(Socket socket) {
        try (Socket s = socket;
             BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
             OutputStream out = s.getOutputStream()) {
            String request = in.readLine();
            if (request == null || request.isEmpty()) return;
            String[] parts = request.split(" ");
            if (parts.length < 2) { respond(out, 400, error("bad_request")); return; }
            String method = parts[0].toUpperCase();
            String target = parts[1];
            String path = target;
            String query = "";
            int q = target.indexOf('?');
            if (q >= 0) { path = target.substring(0, q); query = target.substring(q + 1); }
            Map<String, String> params = parseQuery(query);
            Map<String, String> headers = new HashMap<>();
            String line;
            while ((line = in.readLine()) != null && !line.isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0) headers.put(line.substring(0, colon).trim().toLowerCase(), line.substring(colon + 1).trim());
            }
            String body = readBody(in, headers);

            if ("/".equals(path) || "/health".equals(path)) {
                respond(out, 200, provider.health(token(), running, PORT, OpenCallCompanionService.bluetoothMetaServer(context).isRunning(), OpenCallCompanionService.bleMetaServer(context).isRunning(), OpenCallCompanionService.bleMetaServer(context).lastError()));
                return;
            }

            String supplied = params.containsKey("token") ? params.get("token") : headers.get("x-opencall-token");
            if (!token().equals(supplied)) {
                respond(out, 401, error("bad_or_missing_token"));
                return;
            }
            OpenCallCompanionService.noteMacSeen(context);

            int limit = parseLimit(params.get("limit"));
            try {
                if ("/contacts".equals(path)) respond(out, 200, provider.contacts());
                else if ("/call-state".equals(path) || "/callstate".equals(path)) respond(out, 200, provider.callState());
                else if ("/calls".equals(path) || "/recents".equals(path)) respond(out, 200, provider.calls(limit));
                else if ("/sms".equals(path) || "/messages".equals(path)) respond(out, 200, provider.sms(limit));
                else if ("/dial".equals(path) || "/calls/dial".equals(path)) {
                    if (!"POST".equals(method)) { respond(out, 405, error("method_not_allowed")); return; }
                    JSONObject input = body == null || body.trim().isEmpty() ? new JSONObject() : new JSONObject(body);
                    String number = input.optString("number", params.get("number"));
                    respond(out, 200, provider.dial(number));
                }
                else if ("/answer".equals(path) || "/calls/answer".equals(path)) {
                    if (!"POST".equals(method)) { respond(out, 405, error("method_not_allowed")); return; }
                    respond(out, 200, provider.answer());
                }
                else if ("/hangup".equals(path) || "/calls/hangup".equals(path)) {
                    if (!"POST".equals(method)) { respond(out, 405, error("method_not_allowed")); return; }
                    respond(out, 200, provider.hangup());
                }
                else if ("/send-sms".equals(path) || "/sms/send".equals(path)) {
                    if (!"POST".equals(method)) { respond(out, 405, error("method_not_allowed")); return; }
                    JSONObject input = body == null || body.trim().isEmpty() ? new JSONObject() : new JSONObject(body);
                    String number = input.optString("number", params.get("number"));
                    String text = input.optString("text", params.get("text"));
                    respond(out, 200, provider.sendSms(number, text));
                }
                else respond(out, 404, error("not_found"));
            } catch (SecurityException se) {
                respond(out, 403, error(se.getMessage()));
            } catch (Exception ex) {
                respond(out, 500, error(ex.getClass().getSimpleName() + ": " + ex.getMessage()));
            }
        } catch (Exception ignored) {
        }
    }

    private static String readBody(BufferedReader in, Map<String, String> headers) throws Exception {
        int length = 0;
        try { length = Integer.parseInt(headers.getOrDefault("content-length", "0")); } catch (Exception ignored) {}
        if (length <= 0) return "";
        char[] chars = new char[Math.min(length, 64 * 1024)];
        int total = 0;
        while (total < chars.length) {
            int read = in.read(chars, total, chars.length - total);
            if (read < 0) break;
            total += read;
        }
        return new String(chars, 0, total);
    }

    private void respond(OutputStream out, int status, JSONObject json) throws Exception {
        byte[] body = json.toString().getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Error";
        ByteArrayOutputStream header = new ByteArrayOutputStream();
        header.write(("HTTP/1.1 " + status + " " + reason + "\r\n").getBytes(StandardCharsets.UTF_8));
        header.write("Content-Type: application/json; charset=utf-8\r\n".getBytes(StandardCharsets.UTF_8));
        header.write("Access-Control-Allow-Origin: *\r\n".getBytes(StandardCharsets.UTF_8));
        header.write(("Content-Length: " + body.length + "\r\n").getBytes(StandardCharsets.UTF_8));
        header.write("Connection: close\r\n\r\n".getBytes(StandardCharsets.UTF_8));
        out.write(header.toByteArray());
        out.write(body);
        out.flush();
    }

    private JSONObject error(String message) throws Exception {
        JSONObject obj = new JSONObject();
        obj.put("ok", false);
        obj.put("error", message == null ? "error" : message);
        return obj;
    }

    private String ensureToken() {
        String token = prefs.getString("token", null);
        if (token == null || token.length() < 16) token = resetToken();
        return token;
    }

    private static String randomToken() {
        byte[] bytes = new byte[18];
        new SecureRandom().nextBytes(bytes);
        final char[] alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".toCharArray();
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) sb.append(alphabet[(b & 0xff) % alphabet.length]);
        return sb.toString();
    }

    private static int parseLimit(String s) {
        try { return Math.max(1, Math.min(500, Integer.parseInt(s))); } catch (Exception e) { return 100; }
    }

    private static Map<String, String> parseQuery(String query) throws Exception {
        if (query == null || query.isEmpty()) return Collections.emptyMap();
        Map<String, String> map = new HashMap<>();
        for (String part : query.split("&")) {
            int eq = part.indexOf('=');
            String k = eq >= 0 ? part.substring(0, eq) : part;
            String v = eq >= 0 ? part.substring(eq + 1) : "";
            map.put(URLDecoder.decode(k, "UTF-8"), URLDecoder.decode(v, "UTF-8"));
        }
        return map;
    }

    private static String firstIPv4() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress address : Collections.list(ni.getInetAddresses())) {
                    if (!address.isLoopbackAddress() && address.getHostAddress().indexOf(':') < 0) return address.getHostAddress();
                }
            }
        } catch (Exception ignored) {}
        return null;
    }
}
