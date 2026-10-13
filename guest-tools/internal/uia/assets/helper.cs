using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;

namespace Alcove
{
    // An error whose message goes to the caller as it is.
    public sealed class HelperException : Exception
    {
        public HelperException(string message) : base(message) { }
    }

    public static class UiaHelper
    {
        const int MaxReplyBytes = 8 * 1024 * 1024 - 4096;

        static readonly object outputLock = new object();
        static StreamWriter output;
        static StreamWriter log;

        // Serves requests from stdin until it closes.
        public static void Run()
        {
            try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            Thread worker = new Thread(Loop);
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
            worker.Join();
        }

        static void Loop()
        {
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            UTF8Encoding utf8 = new UTF8Encoding(false);
            StreamReader input = new StreamReader(Console.OpenStandardInput(), utf8);
            output = new StreamWriter(Console.OpenStandardOutput(), utf8);
            output.NewLine = "\n";
            log = new StreamWriter(Console.OpenStandardError(), utf8);
            log.NewLine = "\n";
            JavaScriptSerializer parser = new JavaScriptSerializer();
            parser.MaxJsonLength = int.MaxValue;
            Session session = new Session();
            Log("started in session " + Process.GetCurrentProcess().SessionId + " at " + Native.IntegrityLevel() + " integrity");
            Send("{\"ev\":\"ready\"}");

            string line;
            while ((line = input.ReadLine()) != null)
            {
                if (line.Length == 0)
                {
                    continue;
                }
                Send(Answer(parser, session, line));
            }
        }

        static string Answer(JavaScriptSerializer parser, Session session, string line)
        {
            object id = null;
            string op = "";
            string error;
            try
            {
                Dictionary<string, object> req = Parse(parser, line);
                req.TryGetValue("id", out id);
                op = Params.Str(req, "op") ?? "";
                Dictionary<string, object> reply = new Dictionary<string, object>();
                reply["id"] = id;
                reply["ok"] = true;
                foreach (KeyValuePair<string, object> field in session.Dispatch(op, req))
                {
                    reply[field.Key] = field.Value;
                }
                string text = Json.Write(reply);
                if (text.Length * 3 <= MaxReplyBytes || Encoding.UTF8.GetByteCount(text) <= MaxReplyBytes)
                {
                    return text;
                }
                error = "the answer to '" + op + "' is larger than 8 MiB; ask for less with max, depth, limit or length";
            }
            catch (HelperException e)
            {
                error = e.Message;
            }
            catch (ElementNotAvailableException)
            {
                error = "an element disappeared while it was read; call ui.tree again";
            }
            catch (Exception e)
            {
                Log("'" + op + "' failed: " + e);
                error = "'" + op + "' failed: " + e.Message + "; see helper.log in the agent's uia folder";
            }
            Dictionary<string, object> failure = new Dictionary<string, object>();
            failure["id"] = id;
            failure["ok"] = false;
            failure["error"] = error;
            return Json.Write(failure);
        }

        static Dictionary<string, object> Parse(JavaScriptSerializer parser, string line)
        {
            Dictionary<string, object> req = null;
            try
            {
                req = parser.Deserialize<Dictionary<string, object>>(line);
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            if (req == null)
            {
                throw new HelperException("bad request: the line is not a JSON object; send one JSON object per line");
            }
            return req;
        }

        // Writes one line to stdout.
        public static void Send(string line)
        {
            lock (outputLock)
            {
                output.WriteLine(line);
                output.Flush();
            }
        }

        // Writes one line to stderr, which the agent stores in helper.log.
        public static void Log(string text)
        {
            lock (outputLock)
            {
                try
                {
                    log.WriteLine(DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)
                        + " helper " + Process.GetCurrentProcess().Id + ": " + text);
                    log.Flush();
                }
                catch (IOException) { }
            }
        }
    }

    // Typed access to request fields.
    static class Params
    {
        public static string Str(Dictionary<string, object> req, string key)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return null;
            }
            string s = v as string;
            if (s == null)
            {
                throw new HelperException("'" + key + "' must be a string");
            }
            return s;
        }

        public static bool Has(Dictionary<string, object> req, string key)
        {
            object v;
            return req.TryGetValue(key, out v) && v != null;
        }

        public static int Int(Dictionary<string, object> req, string key, int fallback)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return fallback;
            }
            if (v is int)
            {
                return (int)v;
            }
            if (v is long || v is decimal || v is double)
            {
                double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (d == Math.Floor(d) && d >= int.MinValue && d <= int.MaxValue)
                {
                    return (int)d;
                }
            }
            throw new HelperException("'" + key + "' must be a whole number");
        }

        public static bool Bool(Dictionary<string, object> req, string key, bool fallback)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return fallback;
            }
            if (v is bool)
            {
                return (bool)v;
            }
            throw new HelperException("'" + key + "' must be true or false");
        }
    }

    // Writes strings, numbers, booleans, dictionaries and lists as JSON.
    static class Json
    {
        public static string Write(object value)
        {
            StringBuilder sb = new StringBuilder();
            Append(sb, value);
            return sb.ToString();
        }

        static void Append(StringBuilder sb, object v)
        {
            if (v == null)
            {
                sb.Append("null");
            }
            else if (v is string)
            {
                AppendString(sb, (string)v);
            }
            else if (v is bool)
            {
                sb.Append((bool)v ? "true" : "false");
            }
            else if (v is int || v is long || v is decimal)
            {
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
            }
            else if (v is double)
            {
                double d = (double)v;
                sb.Append(double.IsNaN(d) || double.IsInfinity(d) ? "0" : d.ToString("R", CultureInfo.InvariantCulture));
            }
            else if (v is IDictionary<string, object>)
            {
                sb.Append('{');
                bool first = true;
                foreach (KeyValuePair<string, object> kv in (IDictionary<string, object>)v)
                {
                    if (!first)
                    {
                        sb.Append(',');
                    }
                    first = false;
                    AppendString(sb, kv.Key);
                    sb.Append(':');
                    Append(sb, kv.Value);
                }
                sb.Append('}');
            }
            else if (v is IEnumerable)
            {
                sb.Append('[');
                bool first = true;
                foreach (object item in (IEnumerable)v)
                {
                    if (!first)
                    {
                        sb.Append(',');
                    }
                    first = false;
                    Append(sb, item);
                }
                sb.Append(']');
            }
            else
            {
                AppendString(sb, v.ToString());
            }
        }

        static void AppendString(StringBuilder sb, string s)
        {
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '"' || c == '\\')
                {
                    sb.Append('\\').Append(c);
                }
                else if (c == '\n')
                {
                    sb.Append("\\n");
                }
                else if (c == '\r')
                {
                    sb.Append("\\r");
                }
                else if (c == '\t')
                {
                    sb.Append("\\t");
                }
                else if (c < 0x20 || IsLoneSurrogate(s, i))
                {
                    sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                }
                else
                {
                    sb.Append(c);
                }
            }
            sb.Append('"');
        }

        static bool IsLoneSurrogate(string s, int i)
        {
            char c = s[i];
            if (char.IsHighSurrogate(c))
            {
                return i + 1 >= s.Length || !char.IsLowSurrogate(s[i + 1]);
            }
            if (char.IsLowSurrogate(c))
            {
                return i == 0 || !char.IsHighSurrogate(s[i - 1]);
            }
            return false;
        }
    }

    static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X, Y;
        }

        public const uint GW_OWNER = 4;
        public const uint GA_ROOT = 2;
        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        public const int DWMWA_CLOAKED = 14;

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
        [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, uint length, out uint needed);
        [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

        // The integrity level of this process: low, medium, high, system or unknown.
        public static string IntegrityLevel()
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 8, out token))
            {
                return "unknown";
            }
            try
            {
                uint needed;
                GetTokenInformation(token, 25, IntPtr.Zero, 0, out needed);
                if (needed == 0)
                {
                    return "unknown";
                }
                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    if (!GetTokenInformation(token, 25, buffer, needed, out needed))
                    {
                        return "unknown";
                    }
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    int rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                    if (rid >= 0x4000) { return "system"; }
                    if (rid >= 0x3000) { return "high"; }
                    if (rid >= 0x2000) { return "medium"; }
                    return "low";
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseHandle(token);
            }
        }

        // The DPI awareness of the calling thread: unaware, system or per-monitor.
        public static string DpiAwareness()
        {
            try
            {
                int a = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
                return a == 2 ? "per-monitor" : a == 1 ? "system" : "unaware";
            }
            catch (EntryPointNotFoundException)
            {
                return "unaware";
            }
        }
    }

    sealed class RefEntry
    {
        public int Number;
        public string Key;
        public AutomationElement Element;
        public long Used;
    }

    sealed class Selector
    {
        public string Window;
        public string Role;
        public string Name;
        public string NameContains;
        public string AutomationId;
        public int Index = -1;

        public bool HasCriteria
        {
            get { return Role != null || Name != null || NameContains != null || AutomationId != null; }
        }

        public string ToJson()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            if (Window != null) { d["window"] = Window; }
            if (Role != null) { d["role"] = Role; }
            if (Name != null) { d["name"] = Name; }
            if (NameContains != null) { d["nameContains"] = NameContains; }
            if (AutomationId != null) { d["automationId"] = AutomationId; }
            if (Index >= 0) { d["index"] = Index; }
            return Json.Write(d);
        }
    }

    // The state of one helper process: element refs and the ops.
    sealed class Session
    {
        const int MaxRefs = 20000;
        const int RefsPerStart = 1000000;
        const int DefaultTreeMax = 300;
        const int TreeMaxCap = 2000;
        const int DefaultTreeDepth = 12;
        const int TreeBudgetMs = 20000;
        const int FindBudgetMs = 12000;
        const int TextBudgetMs = 22000;
        const int DefaultFindLimit = 20;
        const int TextCap = 200000;
        const int ValueCut = 200;

        readonly Dictionary<string, RefEntry> refsByKey = new Dictionary<string, RefEntry>();
        readonly Dictionary<int, RefEntry> refsByNumber = new Dictionary<int, RefEntry>();
        int nextRef = 1;
        long clock;

        readonly CacheRequest nodeCacheControl;
        readonly CacheRequest nodeCacheRaw;
        readonly CacheRequest matchCache;
        readonly CacheRequest textCache;
        readonly Stopwatch watch = new Stopwatch();
        int budgetMs;
        readonly Dictionary<string, ControlType> rolesByName = new Dictionary<string, ControlType>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<ControlType> interactiveTypes = new HashSet<ControlType>();

        public Session()
        {
            int start;
            if (int.TryParse(Environment.GetEnvironmentVariable("ALCOVE_UIA_START"), NumberStyles.None, CultureInfo.InvariantCulture, out start))
            {
                nextRef = (start % 2000) * RefsPerStart + 1;
            }
            nodeCacheControl = NodeCache(Automation.ControlViewCondition);
            nodeCacheRaw = NodeCache(Automation.RawViewCondition);
            matchCache = new CacheRequest();
            matchCache.TreeFilter = Automation.ControlViewCondition;
            matchCache.Add(AutomationElement.NameProperty);
            matchCache.Add(AutomationElement.ControlTypeProperty);
            matchCache.Add(AutomationElement.AutomationIdProperty);
            textCache = new CacheRequest();
            textCache.TreeFilter = Automation.ControlViewCondition;
            textCache.Add(AutomationElement.NameProperty);
            textCache.Add(AutomationElement.ControlTypeProperty);
            textCache.Add(AutomationElement.IsPasswordProperty);
            textCache.Add(ValuePattern.ValueProperty);
            foreach (FieldInfo field in typeof(ControlType).GetFields(BindingFlags.Public | BindingFlags.Static))
            {
                ControlType type = field.GetValue(null) as ControlType;
                if (type != null)
                {
                    rolesByName[field.Name] = type;
                }
            }
            interactiveTypes.Add(ControlType.Button);
            interactiveTypes.Add(ControlType.CheckBox);
            interactiveTypes.Add(ControlType.ComboBox);
            interactiveTypes.Add(ControlType.DataItem);
            interactiveTypes.Add(ControlType.Document);
            interactiveTypes.Add(ControlType.Edit);
            interactiveTypes.Add(ControlType.HeaderItem);
            interactiveTypes.Add(ControlType.Hyperlink);
            interactiveTypes.Add(ControlType.ListItem);
            interactiveTypes.Add(ControlType.MenuItem);
            interactiveTypes.Add(ControlType.RadioButton);
            interactiveTypes.Add(ControlType.Slider);
            interactiveTypes.Add(ControlType.Spinner);
            interactiveTypes.Add(ControlType.SplitButton);
            interactiveTypes.Add(ControlType.TabItem);
            interactiveTypes.Add(ControlType.TreeItem);
        }

        static CacheRequest NodeCache(Condition view)
        {
            CacheRequest r = new CacheRequest();
            r.TreeFilter = view;
            r.Add(AutomationElement.NameProperty);
            r.Add(AutomationElement.ControlTypeProperty);
            r.Add(AutomationElement.AutomationIdProperty);
            r.Add(AutomationElement.BoundingRectangleProperty);
            r.Add(AutomationElement.IsEnabledProperty);
            r.Add(AutomationElement.IsOffscreenProperty);
            r.Add(AutomationElement.HasKeyboardFocusProperty);
            r.Add(AutomationElement.IsKeyboardFocusableProperty);
            r.Add(AutomationElement.IsPasswordProperty);
            r.Add(AutomationElement.IsInvokePatternAvailableProperty);
            r.Add(ValuePattern.ValueProperty);
            r.Add(TogglePattern.ToggleStateProperty);
            r.Add(SelectionItemPattern.IsSelectedProperty);
            r.Add(ExpandCollapsePattern.ExpandCollapseStateProperty);
            return r;
        }

        public Dictionary<string, object> Dispatch(string op, Dictionary<string, object> req)
        {
            watch.Restart();
            budgetMs = op == "ui.tree" ? TreeBudgetMs : op == "ui.text" ? TextBudgetMs : FindBudgetMs;
            switch (op)
            {
                case "ping": return Ping();
                case "win.list": return WinList();
                case "ui.tree": return UiTree(req);
                case "ui.find": return UiFind(req);
                case "ui.text": return UiText(req);
                case "ui.rect": return UiRect(req);
                case "ui.focused": return UiFocused();
                default: throw new HelperException("unknown op '" + op + "'; update alcove-agent");
            }
        }

        Dictionary<string, object> Ping()
        {
            Dictionary<string, object> r = new Dictionary<string, object>();
            Process self = Process.GetCurrentProcess();
            r["pong"] = true;
            r["clr"] = Environment.Version.ToString();
            r["pid"] = self.Id;
            r["session"] = self.SessionId;
            r["integrity"] = Native.IntegrityLevel();
            r["dpi"] = Native.DpiAwareness();
            r["refs"] = refsByNumber.Count;
            return r;
        }

        // ---- windows ----

        Dictionary<string, object> WinList()
        {
            IntPtr foreground = Native.GetForegroundWindow();
            List<object> windows = new List<object>();
            foreach (IntPtr hwnd in ListedWindows(foreground))
            {
                windows.Add(WindowObject(hwnd, foreground));
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["windows"] = windows;
            return r;
        }

        // Top-level windows in z-order that are shown and titled, plus the foreground window.
        static List<IntPtr> ListedWindows(IntPtr foreground)
        {
            List<IntPtr> all = new List<IntPtr>();
            Native.EnumWindows(delegate(IntPtr hwnd, IntPtr lParam) { all.Add(hwnd); return true; }, IntPtr.Zero);
            List<IntPtr> listed = new List<IntPtr>();
            foreach (IntPtr hwnd in all)
            {
                if (hwnd == foreground || (Native.IsWindowVisible(hwnd) && !IsCloaked(hwnd) && WindowTitle(hwnd).Length > 0))
                {
                    listed.Add(hwnd);
                }
            }
            return listed;
        }

        static bool IsCloaked(IntPtr hwnd)
        {
            int cloaked;
            return Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0;
        }

        static string WindowTitle(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(1024);
            Native.GetWindowTextW(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        static string WindowClass(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(256);
            Native.GetClassNameW(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        static string ProcessImage(uint pid)
        {
            IntPtr process = Native.OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero)
            {
                return "";
            }
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                uint size = (uint)sb.Capacity;
                if (!Native.QueryFullProcessImageNameW(process, 0, sb, ref size))
                {
                    return "";
                }
                return Path.GetFileName(sb.ToString());
            }
            finally
            {
                Native.CloseHandle(process);
            }
        }

        static string HwndId(IntPtr hwnd)
        {
            return "0x" + hwnd.ToInt64().ToString("x", CultureInfo.InvariantCulture);
        }

        static Dictionary<string, object> WindowObject(IntPtr hwnd, IntPtr foreground)
        {
            Dictionary<string, object> w = new Dictionary<string, object>();
            string cls = WindowClass(hwnd);
            uint pid;
            Native.GetWindowThreadProcessId(hwnd, out pid);
            if (cls == "ApplicationFrameWindow")
            {
                // A packaged app draws inside a frame window of another process; report the app's process.
                IntPtr core = Native.FindWindowExW(hwnd, IntPtr.Zero, "Windows.UI.Core.CoreWindow", null);
                uint corePid;
                if (core != IntPtr.Zero && Native.GetWindowThreadProcessId(core, out corePid) != 0 && corePid != 0)
                {
                    pid = corePid;
                }
            }
            bool minimized = Native.IsIconic(hwnd);
            Native.RECT rect = new Native.RECT();
            if (!minimized && Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out rect, 16) != 0)
            {
                Native.GetWindowRect(hwnd, out rect);
            }
            IntPtr owner = Native.GetWindow(hwnd, Native.GW_OWNER);
            w["id"] = HwndId(hwnd);
            w["title"] = WindowTitle(hwnd);
            w["pid"] = (long)pid;
            w["process"] = ProcessImage(pid);
            w["class"] = cls;
            w["x"] = rect.Left;
            w["y"] = rect.Top;
            w["w"] = rect.Right - rect.Left;
            w["h"] = rect.Bottom - rect.Top;
            w["state"] = minimized ? "minimized" : Native.IsZoomed(hwnd) ? "maximized" : "normal";
            w["foreground"] = hwnd == foreground;
            w["responding"] = !Native.IsHungAppWindow(hwnd);
            w["modal"] = owner != IntPtr.Zero && Native.IsWindow(owner) && !Native.IsWindowEnabled(owner);
            return w;
        }

        // Resolves a window id, "foreground" or a title part to a window handle.
        static IntPtr ResolveWindow(string window)
        {
            IntPtr foreground = Native.GetForegroundWindow();
            if (window == null || window == "foreground")
            {
                if (foreground == IntPtr.Zero)
                {
                    throw new HelperException("no window is in the foreground; pass a window id from win.list");
                }
                return foreground;
            }
            if (window.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                long value;
                if (long.TryParse(window.Substring(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out value))
                {
                    IntPtr hwnd = new IntPtr(value);
                    if (!Native.IsWindow(hwnd))
                    {
                        throw new HelperException("window " + window + " no longer exists; call win.list again");
                    }
                    return hwnd;
                }
            }
            foreach (IntPtr hwnd in ListedWindows(foreground))
            {
                if (WindowTitle(hwnd).IndexOf(window, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return hwnd;
                }
            }
            throw new HelperException("no window has " + Json.Write(window) + " in its title; call win.list to see the open windows");
        }

        // The top-level window that contains the element, or zero.
        static IntPtr TopWindow(AutomationElement element)
        {
            AutomationElement current = element;
            for (int i = 0; i < 64 && current != null; i++)
            {
                int handle = (int)current.GetCurrentPropertyValue(AutomationElement.NativeWindowHandleProperty);
                if (handle != 0)
                {
                    IntPtr root = Native.GetAncestor(new IntPtr(handle), Native.GA_ROOT);
                    return root != IntPtr.Zero ? root : new IntPtr(handle);
                }
                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            return IntPtr.Zero;
        }

        static object WindowObjectOrNull(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
            {
                return null;
            }
            return WindowObject(hwnd, Native.GetForegroundWindow());
        }

        static AutomationElement WindowElement(IntPtr hwnd, CacheRequest cache)
        {
            try
            {
                using (cache.Activate())
                {
                    return AutomationElement.FromHandle(hwnd);
                }
            }
            catch (ElementNotAvailableException)
            {
                throw new HelperException("window " + HwndId(hwnd) + " no longer exists; call win.list again");
            }
        }

        // ---- refs ----

        string RefFor(AutomationElement element)
        {
            string key = null;
            try
            {
                int[] id = element.GetRuntimeId();
                if (id != null && id.Length > 0)
                {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < id.Length; i++)
                    {
                        sb.Append(id[i].ToString(CultureInfo.InvariantCulture)).Append('.');
                    }
                    key = sb.ToString();
                }
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }

            RefEntry entry;
            if (key != null && refsByKey.TryGetValue(key, out entry))
            {
                entry.Element = element;
                entry.Used = ++clock;
                return "e" + entry.Number.ToString(CultureInfo.InvariantCulture);
            }
            entry = new RefEntry();
            entry.Number = nextRef++;
            entry.Key = key;
            entry.Element = element;
            entry.Used = ++clock;
            refsByNumber[entry.Number] = entry;
            if (key != null)
            {
                refsByKey[key] = entry;
            }
            if (refsByNumber.Count > MaxRefs)
            {
                DropOldRefs();
            }
            return "e" + entry.Number.ToString(CultureInfo.InvariantCulture);
        }

        // Forgets the half of the refs that were used least recently.
        void DropOldRefs()
        {
            List<RefEntry> entries = new List<RefEntry>(refsByNumber.Values);
            entries.Sort(delegate(RefEntry a, RefEntry b) { return a.Used.CompareTo(b.Used); });
            for (int i = 0; i < entries.Count / 2; i++)
            {
                ForgetRef(entries[i]);
            }
        }

        void ForgetRef(RefEntry entry)
        {
            refsByNumber.Remove(entry.Number);
            RefEntry byKey;
            if (entry.Key != null && refsByKey.TryGetValue(entry.Key, out byKey) && byKey == entry)
            {
                refsByKey.Remove(entry.Key);
            }
        }

        // Returns the element of a ref with fresh cached properties.
        AutomationElement ResolveRef(string reference)
        {
            int number;
            if (reference.Length < 2 || reference[0] != 'e'
                || !int.TryParse(reference.Substring(1), NumberStyles.None, CultureInfo.InvariantCulture, out number))
            {
                throw new HelperException("ref " + Json.Write(reference) + " is not a ref; refs look like e12 and come from ui.tree or ui.find");
            }
            string gone = "element " + reference + " no longer exists; call ui.tree again";
            RefEntry entry;
            if (!refsByNumber.TryGetValue(number, out entry))
            {
                throw new HelperException(gone);
            }
            try
            {
                AutomationElement fresh = entry.Element.GetUpdatedCache(nodeCacheControl);
                int pid = (int)fresh.GetCurrentPropertyValue(AutomationElement.ProcessIdProperty);
                if (pid == 0)
                {
                    throw new ElementNotAvailableException();
                }
                entry.Element = fresh;
                entry.Used = ++clock;
                return fresh;
            }
            catch (ElementNotAvailableException)
            {
                ForgetRef(entry);
                throw new HelperException(gone);
            }
            catch (COMException)
            {
                ForgetRef(entry);
                throw new HelperException(gone);
            }
        }

        // ---- nodes ----

        static string RoleName(ControlType type)
        {
            if (type == null)
            {
                return "Custom";
            }
            string name = type.ProgrammaticName;
            return name.StartsWith("ControlType.", StringComparison.Ordinal) ? name.Substring(12) : name;
        }

        static string Newlines(string text)
        {
            return text.IndexOf('\r') < 0 ? text : text.Replace("\r\n", "\n").Replace('\r', '\n');
        }

        static string Cut(string text, int max)
        {
            if (text.Length <= max)
            {
                return text;
            }
            int end = max;
            if (char.IsHighSurrogate(text[end - 1]))
            {
                end--;
            }
            return text.Substring(0, end) + "…";
        }

        static string CachedValue(AutomationElement element)
        {
            return element.GetCachedPropertyValue(ValuePattern.ValueProperty, true) as string;
        }

        static bool CachedBool(AutomationElement element, AutomationProperty property)
        {
            object v = element.GetCachedPropertyValue(property, true);
            return v is bool && (bool)v;
        }

        // Builds the node object from the element's cached properties.
        Dictionary<string, object> Node(AutomationElement element, int depth)
        {
            Dictionary<string, object> n = new Dictionary<string, object>();
            n["ref"] = RefFor(element);
            n["depth"] = depth;
            n["role"] = RoleName(element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType);
            n["name"] = (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
            bool password = CachedBool(element, AutomationElement.IsPasswordProperty);
            string value = CachedValue(element);
            if (!string.IsNullOrEmpty(value) && !password)
            {
                n["value"] = Cut(Newlines(value), ValueCut);
            }
            string aid = element.GetCachedPropertyValue(AutomationElement.AutomationIdProperty) as string;
            if (!string.IsNullOrEmpty(aid))
            {
                n["aid"] = aid;
            }
            int x = 0, y = 0, w = 0, h = 0;
            object rectValue = element.GetCachedPropertyValue(AutomationElement.BoundingRectangleProperty);
            if (rectValue is Rect)
            {
                Rect rect = (Rect)rectValue;
                if (!rect.IsEmpty && !double.IsInfinity(rect.Width) && !double.IsInfinity(rect.Height)
                    && !double.IsNaN(rect.X) && !double.IsNaN(rect.Y))
                {
                    x = (int)Math.Round(rect.X);
                    y = (int)Math.Round(rect.Y);
                    w = (int)Math.Round(rect.Width);
                    h = (int)Math.Round(rect.Height);
                }
            }
            n["x"] = x;
            n["y"] = y;
            n["w"] = w;
            n["h"] = h;
            List<object> flags = new List<object>();
            if (CachedBool(element, AutomationElement.HasKeyboardFocusProperty)) { flags.Add("focused"); }
            object enabled = element.GetCachedPropertyValue(AutomationElement.IsEnabledProperty);
            if (enabled is bool && !(bool)enabled) { flags.Add("disabled"); }
            if (CachedBool(element, AutomationElement.IsOffscreenProperty)) { flags.Add("offscreen"); }
            if (CachedBool(element, SelectionItemPattern.IsSelectedProperty)) { flags.Add("selected"); }
            object toggle = element.GetCachedPropertyValue(TogglePattern.ToggleStateProperty, true);
            if (toggle is ToggleState && (ToggleState)toggle == ToggleState.On) { flags.Add("checked"); }
            object expand = element.GetCachedPropertyValue(ExpandCollapsePattern.ExpandCollapseStateProperty, true);
            if (expand is ExpandCollapseState)
            {
                ExpandCollapseState state = (ExpandCollapseState)expand;
                if (state == ExpandCollapseState.Expanded || state == ExpandCollapseState.PartiallyExpanded) { flags.Add("expanded"); }
                if (state == ExpandCollapseState.Collapsed) { flags.Add("collapsed"); }
            }
            if (password) { flags.Add("password"); }
            n["flags"] = flags;
            return n;
        }

        // An element with a name, a value, keyboard focus support or a control type people act on.
        bool IsInteractive(AutomationElement element)
        {
            string name = element.GetCachedPropertyValue(AutomationElement.NameProperty) as string;
            if (!string.IsNullOrEmpty(name) || !string.IsNullOrEmpty(CachedValue(element)))
            {
                return true;
            }
            if (CachedBool(element, AutomationElement.IsKeyboardFocusableProperty)
                || CachedBool(element, AutomationElement.IsInvokePatternAvailableProperty))
            {
                return true;
            }
            ControlType type = element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
            return type != null && interactiveTypes.Contains(type);
        }

        // ---- ui.tree ----

        sealed class TreeWalk
        {
            public TreeWalker Walker;
            public CacheRequest Cache;
            public bool All;
            public int Max;
            public int Depth;
            public List<object> Nodes = new List<object>();
            public bool Truncated;
        }

        Dictionary<string, object> UiTree(Dictionary<string, object> req)
        {
            string filter = Params.Str(req, "filter") ?? "interactive";
            if (filter != "interactive" && filter != "all")
            {
                throw new HelperException("filter must be interactive or all");
            }
            TreeWalk walk = new TreeWalk();
            walk.All = filter == "all";
            walk.Walker = walk.All ? TreeWalker.RawViewWalker : TreeWalker.ControlViewWalker;
            walk.Cache = walk.All ? nodeCacheRaw : nodeCacheControl;
            walk.Depth = Params.Int(req, "depth", DefaultTreeDepth);
            walk.Max = Params.Int(req, "max", DefaultTreeMax);
            if (walk.Depth < 0)
            {
                throw new HelperException("depth must be 0 or more");
            }
            if (walk.Max < 1)
            {
                throw new HelperException("max must be 1 or more");
            }
            if (walk.Max > TreeMaxCap)
            {
                walk.Max = TreeMaxCap;
            }

            AutomationElement root;
            IntPtr hwnd;
            string rootRef = Params.Str(req, "root");
            if (rootRef != null)
            {
                root = ResolveRef(rootRef).GetUpdatedCache(walk.Cache);
                hwnd = TopWindow(root);
            }
            else
            {
                hwnd = ResolveWindow(Params.Str(req, "window"));
                root = WindowElement(hwnd, walk.Cache);
            }

            walk.Nodes.Add(Node(root, 0));
            WalkChildren(walk, root, 0, 1);

            Dictionary<string, object> r = new Dictionary<string, object>();
            r["window"] = WindowObjectOrNull(hwnd);
            r["nodes"] = walk.Nodes;
            r["truncated"] = walk.Truncated;
            return r;
        }

        // Adds the subtree below parent. level is the parent's distance from the root; nodes of the
        // next level get nodeDepth, which counts only the ancestors that are in the answer.
        void WalkChildren(TreeWalk walk, AutomationElement parent, int level, int nodeDepth)
        {
            if (level >= walk.Depth)
            {
                return;
            }
            AutomationElement child;
            try
            {
                child = walk.Walker.GetFirstChild(parent, walk.Cache);
            }
            catch (ElementNotAvailableException)
            {
                return;
            }
            while (child != null && !walk.Truncated)
            {
                if (walk.Nodes.Count >= walk.Max || OutOfTime())
                {
                    walk.Truncated = true;
                    return;
                }
                try
                {
                    bool listed = walk.All || IsInteractive(child);
                    if (listed)
                    {
                        walk.Nodes.Add(Node(child, nodeDepth));
                    }
                    WalkChildren(walk, child, level + 1, listed ? nodeDepth + 1 : nodeDepth);
                    if (walk.Truncated)
                    {
                        return;
                    }
                    child = walk.Walker.GetNextSibling(child, walk.Cache);
                }
                catch (ElementNotAvailableException)
                {
                    return;
                }
            }
        }

        // ---- selectors ----

        static Selector ReadSelector(Dictionary<string, object> req)
        {
            Selector s = new Selector();
            s.Window = Params.Str(req, "window");
            s.Role = Params.Str(req, "role");
            s.Name = Params.Str(req, "name");
            s.NameContains = Params.Str(req, "nameContains");
            s.AutomationId = Params.Str(req, "automationId");
            s.Index = Params.Int(req, "index", -1);
            if (Params.Has(req, "index") && s.Index < 0)
            {
                throw new HelperException("index must be 0 or more");
            }
            return s;
        }

        bool OutOfTime()
        {
            return watch.ElapsedMilliseconds > budgetMs;
        }

        sealed class Search
        {
            public Selector Selector;
            public ControlType Type;
            public int Need;
            public List<AutomationElement> Found = new List<AutomationElement>();
            public bool TimedOut;
        }

        // Walks the control view of the selector's window in tree order and collects the matching
        // elements until `need` are found or the time for the request is used up.
        Search Matches(Selector selector, int need)
        {
            if (!selector.HasCriteria)
            {
                throw new HelperException("pass ref or at least one of role, name, nameContains, automationId");
            }
            Search search = new Search();
            search.Selector = selector;
            search.Need = need;
            if (selector.Role != null && !rolesByName.TryGetValue(selector.Role, out search.Type))
            {
                List<string> names = new List<string>(rolesByName.Keys);
                names.Sort(StringComparer.Ordinal);
                throw new HelperException("unknown role " + Json.Write(selector.Role) + "; use one of " + string.Join(", ", names.ToArray()));
            }
            AutomationElement root = WindowElement(ResolveWindow(selector.Window), matchCache);
            if (IsMatch(search, root))
            {
                search.Found.Add(root);
            }
            if (search.Found.Count < need)
            {
                SearchChildren(search, root);
            }
            return search;
        }

        static bool IsMatch(Search search, AutomationElement element)
        {
            Selector selector = search.Selector;
            if (search.Type != null && search.Type != element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType)
            {
                return false;
            }
            if (selector.Name != null || selector.NameContains != null)
            {
                string name = (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
                if (selector.Name != null && !string.Equals(name, selector.Name, StringComparison.Ordinal))
                {
                    return false;
                }
                if (selector.NameContains != null && name.IndexOf(selector.NameContains, StringComparison.OrdinalIgnoreCase) < 0)
                {
                    return false;
                }
            }
            if (selector.AutomationId != null)
            {
                string aid = (element.GetCachedPropertyValue(AutomationElement.AutomationIdProperty) as string) ?? "";
                if (!string.Equals(aid, selector.AutomationId, StringComparison.Ordinal))
                {
                    return false;
                }
            }
            return true;
        }

        void SearchChildren(Search search, AutomationElement parent)
        {
            AutomationElement child;
            try
            {
                child = TreeWalker.ControlViewWalker.GetFirstChild(parent, matchCache);
            }
            catch (ElementNotAvailableException)
            {
                return;
            }
            while (child != null)
            {
                if (OutOfTime())
                {
                    search.TimedOut = true;
                    return;
                }
                try
                {
                    if (IsMatch(search, child))
                    {
                        search.Found.Add(child);
                    }
                    if (search.Found.Count < search.Need)
                    {
                        SearchChildren(search, child);
                    }
                    if (search.TimedOut || search.Found.Count >= search.Need)
                    {
                        return;
                    }
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child, matchCache);
                }
                catch (ElementNotAvailableException)
                {
                    return;
                }
            }
        }

        string SearchTimedOut(Selector selector)
        {
            return "the search for " + selector.ToJson() + " did not finish within " + (FindBudgetMs / 1000)
                + " s; read the window in parts with ui.tree and root, then use a ref";
        }

        // Returns the element named by "ref" or by the selector fields, with fresh cached properties.
        AutomationElement Target(Dictionary<string, object> req)
        {
            string reference = Params.Str(req, "ref");
            if (reference != null)
            {
                return ResolveRef(reference);
            }
            Selector selector = ReadSelector(req);
            int index = selector.Index < 0 ? 0 : selector.Index;
            Search search = Matches(selector, index + 1);
            if (index >= search.Found.Count)
            {
                if (search.TimedOut)
                {
                    throw new HelperException(SearchTimedOut(selector));
                }
                throw new HelperException("no element matches " + selector.ToJson() + "; call ui.tree to see what exists");
            }
            try
            {
                return search.Found[index].GetUpdatedCache(nodeCacheControl);
            }
            catch (ElementNotAvailableException)
            {
                throw new HelperException("no element matches " + selector.ToJson() + "; call ui.tree to see what exists");
            }
        }

        // ---- ui.find ----

        Dictionary<string, object> UiFind(Dictionary<string, object> req)
        {
            Selector selector = ReadSelector(req);
            int limit = Params.Int(req, "limit", DefaultFindLimit);
            if (limit < 1)
            {
                throw new HelperException("limit must be 1 or more");
            }
            if (limit > TreeMaxCap)
            {
                limit = TreeMaxCap;
            }
            int first = selector.Index < 0 ? 0 : selector.Index;
            Search search = Matches(selector, selector.Index < 0 ? limit : first + 1);
            if (search.TimedOut && search.Found.Count <= first)
            {
                throw new HelperException(SearchTimedOut(selector));
            }
            List<object> nodes = new List<object>();
            for (int i = first; i < search.Found.Count; i++)
            {
                try
                {
                    nodes.Add(Node(search.Found[i].GetUpdatedCache(nodeCacheControl), 0));
                }
                catch (ElementNotAvailableException) { }
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["nodes"] = nodes;
            if (search.TimedOut)
            {
                r["truncated"] = true;
            }
            return r;
        }

        // ---- ui.text ----

        Dictionary<string, object> UiText(Dictionary<string, object> req)
        {
            string mode = Params.Str(req, "mode") ?? "auto";
            if (mode != "auto" && mode != "pattern" && mode != "descendants")
            {
                throw new HelperException("mode must be auto, pattern or descendants");
            }
            int offset = Params.Int(req, "offset", 0);
            int length = Params.Int(req, "length", TextCap);
            if (offset < 0)
            {
                throw new HelperException("offset must be 0 or more");
            }
            if (length < 1)
            {
                throw new HelperException("length must be 1 or more");
            }
            if (length > TextCap)
            {
                length = TextCap;
            }
            AutomationElement element = Target(req);

            string text = null;
            string source = null;
            if (mode != "descendants")
            {
                object pattern;
                if (element.TryGetCurrentPattern(TextPattern.Pattern, out pattern))
                {
                    text = ((TextPattern)pattern).DocumentRange.GetText(-1) ?? "";
                    source = "text";
                }
                else if (mode == "pattern")
                {
                    throw new HelperException("the element has no text pattern; use mode auto or descendants");
                }
            }
            // An empty value counts as the text of an edit or a document only; other elements go on to their descendants.
            string value = null;
            if (text == null && mode == "auto" && !CachedBool(element, AutomationElement.IsPasswordProperty))
            {
                value = CachedValue(element);
                ControlType type = element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
                if (value != null && (value.Length > 0 || type == ControlType.Edit || type == ControlType.Document))
                {
                    text = value;
                    source = "value";
                }
            }
            if (text == null)
            {
                string joined = DescendantNames(element);
                if (joined.Length > 0 || mode == "descendants")
                {
                    text = joined;
                    source = "descendants";
                }
            }
            if (text == null && value != null)
            {
                text = value;
                source = "value";
            }
            if (text == null)
            {
                text = (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
                source = "name";
            }

            text = Newlines(text);
            int total = text.Length;
            int start = Math.Min(offset, total);
            int end = (int)Math.Min((long)start + length, total);
            if (start > 0 && start < total && char.IsLowSurrogate(text[start]) && char.IsHighSurrogate(text[start - 1]))
            {
                start--;
            }
            if (end > start && end < total && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end]))
            {
                end++;
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["text"] = text.Substring(start, end - start);
            r["total"] = total;
            r["source"] = source;
            return r;
        }

        // The text, list item, edit and document elements below the element, one per line: the value
        // of an edit or document that has one, the name otherwise.
        string DescendantNames(AutomationElement element)
        {
            StringBuilder sb = new StringBuilder();
            if (!CollectText(element, sb))
            {
                throw new HelperException("the text below the element was not read within " + (TextBudgetMs / 1000)
                    + " s; read a smaller element: list its parts with ui.tree and root");
            }
            return sb.ToString();
        }

        bool CollectText(AutomationElement parent, StringBuilder sb)
        {
            AutomationElement child;
            try
            {
                child = TreeWalker.ControlViewWalker.GetFirstChild(parent, textCache);
            }
            catch (ElementNotAvailableException)
            {
                return true;
            }
            while (child != null)
            {
                if (OutOfTime())
                {
                    return false;
                }
                try
                {
                    ControlType type = child.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
                    if (type == ControlType.Text || type == ControlType.ListItem || type == ControlType.Edit || type == ControlType.Document)
                    {
                        string line = child.GetCachedPropertyValue(AutomationElement.NameProperty) as string;
                        if (type == ControlType.Edit || type == ControlType.Document)
                        {
                            string value = CachedValue(child);
                            if (!string.IsNullOrEmpty(value) && !CachedBool(child, AutomationElement.IsPasswordProperty))
                            {
                                line = value;
                            }
                        }
                        if (!string.IsNullOrEmpty(line))
                        {
                            if (sb.Length > 0)
                            {
                                sb.Append('\n');
                            }
                            sb.Append(line);
                        }
                    }
                    if (!CollectText(child, sb))
                    {
                        return false;
                    }
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child, textCache);
                }
                catch (ElementNotAvailableException)
                {
                    return true;
                }
            }
            return true;
        }

        // ---- ui.rect ----

        Dictionary<string, object> UiRect(Dictionary<string, object> req)
        {
            AutomationElement element = Target(req);
            if (Params.Bool(req, "scroll", false))
            {
                object pattern;
                if (element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out pattern))
                {
                    try
                    {
                        ((ScrollItemPattern)pattern).ScrollIntoView();
                        Thread.Sleep(150);
                    }
                    catch (InvalidOperationException) { }
                    element = element.GetUpdatedCache(nodeCacheControl);
                }
            }
            Dictionary<string, object> node = Node(element, 0);
            int x = (int)node["x"], y = (int)node["y"], w = (int)node["w"], h = (int)node["h"];
            int cx = x + w / 2, cy = y + h / 2;
            List<object> flags = (List<object>)node["flags"];
            string blocked = null;
            if (w <= 0 || h <= 0)
            {
                blocked = "the element has no rectangle on screen";
            }
            else if (flags.Contains("offscreen"))
            {
                blocked = "the element is scrolled out of view or hidden; pass scroll: true or scroll it into view";
            }
            else if (flags.Contains("disabled"))
            {
                blocked = "the element is disabled";
            }
            else
            {
                int left = Native.GetSystemMetrics(76), top = Native.GetSystemMetrics(77);
                int right = left + Native.GetSystemMetrics(78), bottom = top + Native.GetSystemMetrics(79);
                if (cx < left || cy < top || cx >= right || cy >= bottom)
                {
                    blocked = "the centre of the element is outside the screen; move its window with win.action";
                }
                else
                {
                    IntPtr own = TopWindow(element);
                    Native.POINT point = new Native.POINT();
                    point.X = cx;
                    point.Y = cy;
                    IntPtr hit = Native.WindowFromPoint(point);
                    IntPtr hitTop = hit == IntPtr.Zero ? IntPtr.Zero : Native.GetAncestor(hit, Native.GA_ROOT);
                    if (own != IntPtr.Zero && hitTop != own)
                    {
                        blocked = "window " + HwndId(hitTop) + " " + Json.Write(WindowTitle(hitTop))
                            + " covers the centre of the element; focus the element's window with win.action";
                    }
                }
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["node"] = node;
            r["cx"] = cx;
            r["cy"] = cy;
            r["clickable"] = blocked == null;
            if (blocked != null)
            {
                r["blocked"] = blocked;
            }
            return r;
        }

        // ---- ui.focused ----

        Dictionary<string, object> UiFocused()
        {
            AutomationElement element;
            try
            {
                using (nodeCacheControl.Activate())
                {
                    element = AutomationElement.FocusedElement;
                }
            }
            catch (ElementNotAvailableException)
            {
                element = null;
            }
            if (element == null)
            {
                throw new HelperException("no element has the keyboard focus; click a window or use win.action focus");
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["node"] = Node(element, 0);
            r["window"] = WindowObjectOrNull(TopWindow(element));
            return r;
        }
    }
}
