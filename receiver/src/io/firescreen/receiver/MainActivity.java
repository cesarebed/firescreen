package io.firescreen.receiver;

import android.app.Activity;
import android.graphics.Color;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;

/** Full-screen surface plus a status line; the stream server renders into the surface. */
public class MainActivity extends Activity
        implements SurfaceHolder.Callback, StreamServer.Listener, StreamServer.Settings {

    static final int PORT = 7878;
    static final String SERVICE_TYPE = "_firescreen._tcp.";

    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;

    private TextView status;
    private StreamServer server;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        SurfaceView surface = new SurfaceView(this);
        surface.getHolder().addCallback(this);
        root.addView(surface, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(28);
        status.setGravity(Gravity.CENTER);
        root.addView(status, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        setContentView(root);
        showWaiting();
    }

    // StreamServer.Settings

    @Override
    public long avOffsetMs() {
        return getSharedPreferences("firescreen", MODE_PRIVATE).getLong("avOffsetMs", 0);
    }

    @Override
    public void saveAvOffsetMs(long ms) {
        getSharedPreferences("firescreen", MODE_PRIVATE).edit().putLong("avOffsetMs", ms).apply();
    }

    @Override
    public String deviceName() {
        return Build.MODEL;
    }

    /** Lets the Mac find this TV on the network without typing an IP address. */
    private void advertise() {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("FireScreen " + Build.MODEL);
        info.setServiceType(SERVICE_TYPE);
        info.setPort(PORT);
        nsd = (NsdManager) getSystemService(NSD_SERVICE);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo i) { }
            @Override public void onRegistrationFailed(NsdServiceInfo i, int error) { registration = null; }
            @Override public void onServiceUnregistered(NsdServiceInfo i) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo i, int error) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    @Override
    protected void onStart() {
        super.onStart();
        advertise();
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (nsd != null && registration != null) {
            try {
                nsd.unregisterService(registration);
            } catch (IllegalArgumentException ignored) {
            }
        }
        registration = null;
    }

    @Override
    protected void onResume() {
        super.onResume();
        root().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    private View root() {
        return getWindow().getDecorView();
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        server = new StreamServer(PORT, holder.getSurface(), this, this);
        server.start();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        if (server != null) {
            server.shutdown();
            server = null;
        }
    }

    @Override
    public void onStreaming(final String description) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                status.setText("");
                status.setVisibility(View.GONE);
            }
        });
    }

    @Override
    public void onIdle(final String reason) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                showWaiting();
                if (reason != null) {
                    status.append("\n\n" + reason);
                }
            }
        });
    }

    private void showWaiting() {
        status.setVisibility(View.VISIBLE);
        status.setText("FireScreen\n\nWaiting for your Mac on " + localAddress() + ":" + PORT);
    }

    private static String localAddress() {
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback()) continue;
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address) return addr.getHostAddress();
                }
            }
        } catch (Exception ignored) {
        }
        return "?";
    }
}
