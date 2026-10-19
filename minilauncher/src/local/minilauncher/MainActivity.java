package local.minilauncher;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextClock;
import android.widget.TextView;
import android.widget.Toast;

import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Minimal D-pad home screen: a Settings tile followed by every launchable app. */
public class MainActivity extends Activity {

    private static final int COLUMNS = 6;
    private static final int TILE_W = 176;
    private static final int TILE_H = 132;
    private static final int ART_H = 99;
    private static final int BG = 0xFF101418;
    private static final int TILE_BG = 0xFF1E252C;
    private static final int ACCENT = 0xFF4FC3F7;

    private final List<Entry> entries = new ArrayList<>();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private GridView grid;
    private Adapter adapter;
    private volatile int loadGeneration;

    private final BroadcastReceiver packageReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) { reload(); }
    };

    static final class Entry {
        final CharSequence label;
        final Drawable art;
        final boolean isBanner;
        final Intent intent;
        final String pkg;
        Entry(CharSequence label, Drawable art, boolean isBanner, Intent intent, String pkg) {
            this.label = label; this.art = art; this.isBanner = isBanner; this.intent = intent; this.pkg = pkg;
        }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().getDecorView().setBackgroundColor(BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(48, 28, 48, 16);
        root.setBackgroundColor(BG);

        TextClock clock = new TextClock(this);
        clock.setFormat12Hour("h:mm  ·  EEE d MMM");
        clock.setFormat24Hour("HH:mm  ·  EEE d MMM");
        clock.setTextColor(Color.WHITE);
        clock.setTextSize(26);
        clock.setGravity(Gravity.END);
        root.addView(clock, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        grid = new GridView(this);
        grid.setNumColumns(COLUMNS);
        grid.setColumnWidth(TILE_W);
        grid.setStretchMode(GridView.STRETCH_SPACING_UNIFORM);
        grid.setVerticalSpacing(22);
        grid.setHorizontalSpacing(16);
        grid.setPadding(8, 24, 8, 24);
        grid.setClipToPadding(false);
        grid.setClipChildren(false);
        grid.setSelector(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
        grid.setDrawSelectorOnTop(false);
        grid.setVerticalScrollBarEnabled(false);
        adapter = new Adapter();
        grid.setAdapter(adapter);
        grid.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override public void onItemClick(AdapterView<?> p, View v, int pos, long id) { launch(entries.get(pos)); }
        });
        grid.setOnItemLongClickListener(new AdapterView.OnItemLongClickListener() {
            @Override public boolean onItemLongClick(AdapterView<?> p, View v, int pos, long id) {
                openAppInfo(entries.get(pos)); return true;
            }
        });
        grid.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> p, View v, int pos, long id) { highlight(); }
            @Override public void onNothingSelected(AdapterView<?> p) { highlight(); }
        });
        grid.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override public void onFocusChange(View v, boolean has) { highlight(); }
        });
        root.addView(grid, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);

        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_PACKAGE_ADDED);
        f.addAction(Intent.ACTION_PACKAGE_REMOVED);
        f.addAction(Intent.ACTION_PACKAGE_CHANGED);
        f.addAction(Intent.ACTION_PACKAGE_REPLACED);
        f.addDataScheme("package");
        registerReceiver(packageReceiver, f);

        reload();
    }

    @Override
    protected void onDestroy() {
        unregisterReceiver(packageReceiver);
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        grid.requestFocus();
        highlight();
    }

    @Override
    public void onBackPressed() {
        // Home screen: Back goes nowhere.
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_MENU) {
            int pos = grid.getSelectedItemPosition();
            if (pos >= 0 && pos < entries.size()) { openAppInfo(entries.get(pos)); return true; }
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        // Pressing Home while already home jumps back to the first tile.
        if (!entries.isEmpty()) grid.setSelection(0);
    }

    private void reload() {
        final int gen = ++loadGeneration;
        final PackageManager pm = getPackageManager();
        new Thread(new Runnable() {
            @Override public void run() {
                final List<Entry> loaded = loadEntries(pm);
                ui.post(new Runnable() {
                    @Override public void run() {
                        if (gen != loadGeneration) return;
                        int keep = Math.max(0, grid.getSelectedItemPosition());
                        entries.clear();
                        entries.addAll(loaded);
                        adapter.notifyDataSetChanged();
                        grid.setSelection(Math.min(keep, entries.size() - 1));
                        highlight();
                    }
                });
            }
        }, "load-apps").start();
    }

    private List<Entry> loadEntries(PackageManager pm) {
        List<Entry> out = new ArrayList<>();
        Entry settings = settingsEntry(pm);
        if (settings != null) out.add(settings);

        Set<String> seen = new HashSet<>();
        seen.add(getPackageName());
        seen.add("com.hikeymasterprovision"); // factory key-provisioning tool
        List<Entry> apps = new ArrayList<>();
        // Leanback activities first so TV apps use their TV entry point and banner.
        String[] categories = {Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER};
        for (String cat : categories) {
            Intent q = new Intent(Intent.ACTION_MAIN).addCategory(cat);
            for (ResolveInfo ri : pm.queryIntentActivities(q, 0)) {
                ActivityInfo ai = ri.activityInfo;
                if (!seen.add(ai.packageName)) continue;
                if (settings != null && ai.packageName.equals(settings.pkg)) continue;
                Intent launch = new Intent(Intent.ACTION_MAIN)
                        .addCategory(cat)
                        .setComponent(new ComponentName(ai.packageName, ai.name))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                Drawable banner = null;
                try { banner = ai.loadBanner(pm); } catch (Exception ignored) { }
                if (banner == null) {
                    try { banner = pm.getApplicationBanner(ai.packageName); } catch (Exception ignored) { }
                }
                Drawable art = banner != null ? banner : ri.loadIcon(pm);
                // The phone-style settings app would otherwise share the "Settings" name with the TV one.
                CharSequence label = "com.android.settings".equals(ai.packageName) ? "Android Settings" : ri.loadLabel(pm);
                apps.add(new Entry(label, art, banner != null, launch, ai.packageName));
            }
        }
        final Collator collator = Collator.getInstance();
        Collections.sort(apps, new Comparator<Entry>() {
            @Override public int compare(Entry a, Entry b) { return collator.compare(a.label.toString(), b.label.toString()); }
        });
        out.addAll(apps);
        return out;
    }

    private Entry settingsEntry(PackageManager pm) {
        Intent[] candidates = {
            new Intent(Settings.ACTION_SETTINGS).setPackage("com.android.tv.settings"),
            new Intent(Settings.ACTION_SETTINGS),
        };
        for (Intent i : candidates) {
            ResolveInfo ri = pm.resolveActivity(i, 0);
            if (ri == null || ri.activityInfo == null) continue;
            ActivityInfo ai = ri.activityInfo;
            if ("android".equals(ai.packageName)) continue; // chooser, not a real settings app
            Intent launch = new Intent(Settings.ACTION_SETTINGS)
                    .setComponent(new ComponentName(ai.packageName, ai.name))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            return new Entry("Settings", ri.loadIcon(pm), false, launch, ai.packageName);
        }
        return null;
    }

    private void launch(Entry e) {
        try {
            startActivity(e.intent);
        } catch (Exception ex) {
            Toast.makeText(this, "Can't open " + e.label, Toast.LENGTH_SHORT).show();
        }
    }

    private void openAppInfo(Entry e) {
        try {
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + e.pkg))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception ex) {
            Toast.makeText(this, "No app info screen", Toast.LENGTH_SHORT).show();
        }
    }

    /** Grows the selected tile; GridView's own selector is hidden. */
    private void highlight() {
        int sel = grid.hasFocus() ? grid.getSelectedItemPosition() : -1;
        int first = grid.getFirstVisiblePosition();
        for (int i = 0; i < grid.getChildCount(); i++) {
            View child = grid.getChildAt(i);
            boolean on = first + i == sel;
            child.setSelected(on);
            child.animate().scaleX(on ? 1.12f : 1f).scaleY(on ? 1.12f : 1f).setDuration(on ? 90 : 0).start();
            child.setTranslationZ(on ? 8f : 0f);
        }
    }

    private final class Adapter extends BaseAdapter {
        @Override public int getCount() { return entries.size(); }
        @Override public Object getItem(int pos) { return entries.get(pos); }
        @Override public long getItemId(int pos) { return pos; }

        @Override
        public View getView(int pos, View convert, ViewGroup parent) {
            Holder h;
            if (convert == null) {
                h = new Holder(MainActivity.this);
                convert = h.root;
                convert.setTag(h);
            } else {
                h = (Holder) convert.getTag();
            }
            Entry e = entries.get(pos);
            h.bind(e);
            boolean on = grid.hasFocus() && pos == grid.getSelectedItemPosition();
            convert.setSelected(on);
            convert.setScaleX(on ? 1.12f : 1f);
            convert.setScaleY(on ? 1.12f : 1f);
            return convert;
        }
    }

    private static final class Holder {
        final LinearLayout root;
        final FrameLayout artBox;
        final ImageView art;
        final TextView label;

        Holder(Context c) {
            root = new LinearLayout(c);
            root.setOrientation(LinearLayout.VERTICAL);
            root.setLayoutParams(new AdapterView.LayoutParams(TILE_W, TILE_H));
            root.setDuplicateParentStateEnabled(false);

            artBox = new FrameLayout(c);
            artBox.setBackground(tileBackground());
            artBox.setPadding(4, 4, 4, 4);
            art = new ImageView(c);
            artBox.addView(art, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            root.addView(artBox, new LinearLayout.LayoutParams(TILE_W, ART_H));

            label = new TextView(c);
            label.setTextColor(0xFFCFD8DC);
            label.setTextSize(14);
            label.setSingleLine(true);
            label.setEllipsize(TextUtils.TruncateAt.END);
            label.setGravity(Gravity.CENTER_HORIZONTAL);
            label.setPadding(0, 6, 0, 0);
            root.addView(label, new LinearLayout.LayoutParams(TILE_W, ViewGroup.LayoutParams.WRAP_CONTENT));
        }

        void bind(Entry e) {
            art.setImageDrawable(e.art);
            if (e.isBanner) {
                art.setScaleType(ImageView.ScaleType.FIT_XY);
                art.setPadding(0, 0, 0, 0);
            } else {
                art.setScaleType(ImageView.ScaleType.FIT_CENTER);
                art.setPadding(0, 14, 0, 14);
            }
            label.setText(e.label);
        }

        private static StateListDrawable tileBackground() {
            GradientDrawable normal = new GradientDrawable();
            normal.setColor(TILE_BG);
            normal.setCornerRadius(10);
            GradientDrawable selected = new GradientDrawable();
            selected.setColor(TILE_BG);
            selected.setCornerRadius(10);
            selected.setStroke(4, ACCENT);
            StateListDrawable s = new StateListDrawable();
            s.addState(new int[]{android.R.attr.state_selected}, selected);
            s.addState(new int[]{}, normal);
            return s;
        }
    }
}
