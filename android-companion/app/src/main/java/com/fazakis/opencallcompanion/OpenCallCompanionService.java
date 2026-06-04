package com.fazakis.opencallcompanion;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.os.Build;
import android.os.IBinder;

public class OpenCallCompanionService extends Service {
    private static LocalHttpServer server;
    private static BluetoothMetaServer bluetoothMetaServer;
    private static BleMetaServer bleMetaServer;

    static LocalHttpServer server(android.content.Context context) {
        if (server == null) server = new LocalHttpServer(context.getApplicationContext());
        return server;
    }

    static BluetoothMetaServer bluetoothMetaServer(android.content.Context context) {
        if (bluetoothMetaServer == null) bluetoothMetaServer = new BluetoothMetaServer(context.getApplicationContext(), server(context));
        return bluetoothMetaServer;
    }

    static BleMetaServer bleMetaServer(android.content.Context context) {
        if (bleMetaServer == null) bleMetaServer = new BleMetaServer(context.getApplicationContext(), server(context));
        return bleMetaServer;
    }

    @Override public void onCreate() {
        super.onCreate();
        startForeground(42, notification());
        server(this).start();
        bluetoothMetaServer(this).start();
        bleMetaServer(this).start();
        refreshNotification();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        server(this).start();
        bluetoothMetaServer(this).start();
        bleMetaServer(this).start();
        refreshNotification();
        return START_STICKY;
    }

    @Override public void onTaskRemoved(Intent rootIntent) {
        Intent restart = new Intent(getApplicationContext(), OpenCallCompanionService.class);
        PendingIntent pending = PendingIntent.getService(this, 99, restart, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        AlarmManager alarm = (AlarmManager) getSystemService(ALARM_SERVICE);
        if (alarm != null) alarm.set(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + 1000, pending);
        super.onTaskRemoved(rootIntent);
    }

    @Override public void onDestroy() {
        bleMetaServer(this).stop();
        bluetoothMetaServer(this).stop();
        server(this).stop();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    private void refreshNotification() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(42, notification());
    }

    private Bitmap notificationLargeIcon() {
        int size = 96;
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setColor(Color.rgb(37, 99, 235));
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint);

        paint.setColor(Color.rgb(96, 165, 250));
        paint.setAlpha(90);
        canvas.drawCircle(size / 2f, size / 2f, size * 0.39f, paint);
        paint.setAlpha(255);

        Path phone = new Path();
        phone.moveTo(6.62f, 10.79f);
        phone.cubicTo(8.06f, 13.62f, 10.38f, 15.93f, 13.21f, 17.38f);
        phone.lineTo(15.41f, 15.18f);
        phone.cubicTo(15.68f, 14.91f, 16.08f, 14.82f, 16.43f, 14.94f);
        phone.cubicTo(17.55f, 15.31f, 18.75f, 15.5f, 20f, 15.5f);
        phone.cubicTo(20.55f, 15.5f, 21f, 15.95f, 21f, 16.5f);
        phone.lineTo(21f, 20f);
        phone.cubicTo(21f, 20.55f, 20.55f, 21f, 20f, 21f);
        phone.cubicTo(10.61f, 21f, 3f, 13.39f, 3f, 4f);
        phone.cubicTo(3f, 3.45f, 3.45f, 3f, 4f, 3f);
        phone.lineTo(7.5f, 3f);
        phone.cubicTo(8.05f, 3f, 8.5f, 3.45f, 8.5f, 4f);
        phone.cubicTo(8.5f, 5.25f, 8.69f, 6.45f, 9.06f, 7.57f);
        phone.cubicTo(9.17f, 7.92f, 9.09f, 8.31f, 8.81f, 8.59f);
        phone.lineTo(6.62f, 10.79f);
        phone.close();

        canvas.save();
        canvas.translate(18f, 18f);
        canvas.scale(2.55f, 2.55f);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.WHITE);
        canvas.drawPath(phone, paint);
        canvas.restore();
        return bitmap;
    }

    private Notification notification() {
        String channelId = "opencall_companion";
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(channelId, "OpenCall Companion", NotificationManager.IMPORTANCE_LOW);
            getSystemService(NotificationManager.class).createNotificationChannel(ch);
        }
        Intent openIntent = new Intent(this, MainActivity.class);
        PendingIntent openPending = PendingIntent.getActivity(this, 1, openIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Intent copyIntent = new Intent(this, MainActivity.class);
        copyIntent.setAction(MainActivity.ACTION_COPY_INFO);
        PendingIntent copyPending = PendingIntent.getActivity(this, 2, copyIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, channelId) : new Notification.Builder(this);
        return b.setSmallIcon(com.fazakis.opencallcompanion.R.drawable.ic_stat_phone)
                .setContentTitle("OpenCall Companion running")
                .setContentText(server(this).localUrl() + " • Bluetooth discovery " + ((bluetoothMetaServer(this).isRunning() || bleMetaServer(this).isRunning()) ? "on" : "starting"))
                .setContentIntent(openPending)
                .setLargeIcon(notificationLargeIcon())
                .setColor(Color.rgb(37, 99, 235))
                .addAction(com.fazakis.opencallcompanion.R.drawable.ic_stat_phone, "Open", openPending)
                .addAction(com.fazakis.opencallcompanion.R.drawable.ic_stat_phone, "Copy info", copyPending)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();
    }
}
