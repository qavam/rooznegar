import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shamsi_date/shamsi_date.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// سرویس اعلان‌های بومی اندروید (Local Notifications)
// ---------------------------------------------------------------------------
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    tz.initializeTimeZones();
    // ✅ اصلاح: تعیین منطقه زمانی محلی (تهران) تا آلارم‌ها در ساعت درست فعال شوند
    try {
      final tehran = tz.getLocation('Asia/Tehran');
      tz.setLocalLocation(tehran);
    } catch (_) {
      // اگر داده timezone بارگذاری نشد، UTC به‌صورت پیش‌فرض باقی می‌ماند
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (_) {},
    );

    // درخواست دسترسی اعلان‌ها در اندروید ۱۳ به بعد
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> scheduleAlarm({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    if (scheduledDate.isBefore(DateTime.now())) return;
    final tzDateTime = tz.TZDateTime.from(scheduledDate, tz.local);
    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tzDateTime,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'rooznegar_tasks',
          'یادآوری وظایف روزنگار',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }
}

// ---------------------------------------------------------------------------
// دیتابیس بومی آفلاین SQLite
// ---------------------------------------------------------------------------
class Task {
  final int? id;
  final String title;
  final String category;
  final String dueDate; // YYYY-MM-DD
  final String dueTime; // HH:mm
  final String priority;
  final String recurrence;
  final bool isCompleted;

  Task({
    this.id,
    required this.title,
    required this.category,
    required this.dueDate,
    required this.dueTime,
    required this.priority,
    required this.recurrence,
    this.isCompleted = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'category': category,
        'due_date': dueDate,
        'due_time': dueTime,
        'priority': priority,
        'recurrence': recurrence,
        'is_completed': isCompleted ? 1 : 0,
      };

  factory Task.fromMap(Map<String, dynamic> map) => Task(
        id: map['id'] as int?,
        title: map['title'] as String,
        category: map['category'] as String,
        dueDate: map['due_date'] as String,
        dueTime: map['due_time'] as String,
        priority: map['priority'] as String,
        recurrence: map['recurrence'] as String,
        isCompleted: (map['is_completed'] as int) == 1,
      );
}

class AppDatabase {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    _db = await _initDB('rooznegar.db');
    return _db!;
  }

  static Future<Database> _initDB(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, fileName);
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  due_date TEXT NOT NULL,
  due_time TEXT NOT NULL,
  priority TEXT NOT NULL,
  recurrence TEXT NOT NULL,
  is_completed INTEGER DEFAULT 0,
  completed_at TEXT
)
''');
      },
    );
  }

  static Future<int> insertTask(Task task) async {
    final db = await instance;
    return await db.insert('tasks', task.toMap());
  }

  static Future<List<Task>> getTasks({
    String query = '',
    String category = 'همه',
    String period = 'همه',
    bool showCompleted = false,
  }) async {
    final db = await instance;
    String where = showCompleted ? '1=1' : 'is_completed = 0';
    List<String> args = [];
    if (query.isNotEmpty) {
      where += ' AND (title LIKE ? OR category LIKE ?)';
      args.addAll(['%$query%', '%$query%']);
    }
    if (category != 'همه') {
      where += ' AND category = ?';
      args.add(category);
    }
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    if (period == 'امروز') {
      where += ' AND due_date = ?';
      args.add(todayStr);
    } else if (period == 'عقب‌افتاده‌ها') {
      where += ' AND due_date < ? AND is_completed = 0';
      args.add(todayStr);
    }
    final result = await db.query(
      'tasks',
      where: where,
      whereArgs: args,
      orderBy: 'is_completed ASC, due_date ASC, due_time ASC',
    );
    return result.map((e) => Task.fromMap(e)).toList();
  }

  static Future<void> completeTask(Task task) async {
    final db = await instance;
    await db.update(
      'tasks',
      {'is_completed': 1, 'completed_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [task.id],
    );
    // تکرار خودکار
    if (task.recurrence != 'بدون تکرار') {
      final DateTime current = DateTime.parse(task.dueDate);
      DateTime next;
      if (task.recurrence == 'روزانه') {
        next = current.add(const Duration(days: 1));
      } else if (task.recurrence == 'هفتگی') {
        next = current.add(const Duration(days: 7));
      } else {
        // ✅ اصلاح: تکرار ماهانه بدون سرریز در پایان سال و روزهای ۲۹/۳۰/۳۱
        next = _addOneMonthSafe(current);
      }
      await insertTask(Task(
        title: task.title,
        category: task.category,
        dueDate: next.toIso8601String().substring(0, 10),
        dueTime: task.dueTime,
        priority: task.priority,
        recurrence: task.recurrence,
      ));
    }
  }

  /// ماه بعد را به‌صورت امن محاسبه می‌کند؛ اگر روز فعلی در ماه بعد وجود نداشت،
  /// به آخرین روزِ آن ماه می‌رود (مثلاً ۳۱ فروردین → ۳۱ اردیبهشت نیست، ۳۰ اردیبهشت).
  static DateTime _addOneMonthSafe(DateTime d) {
    int newMonth = d.month + 1;
    int newYear = d.year;
    if (newMonth > 12) {
      newMonth = 1;
      newYear += 1;
    }
    // پیدا کردن آخرین روزِ ماه مقصد
    final firstOfNext = DateTime(newYear, newMonth, 1);
    final lastDayOfMonth = firstOfNext.subtract(const Duration(days: 1)).day;
    final day = d.day < lastDayOfMonth ? d.day : lastDayOfMonth;
    return DateTime(newYear, newMonth, day);
  }

  static Future<void> deleteTask(int id) async {
    final db = await instance;
    await db.delete('tasks', where: 'id = ?', whereArgs: [id]);
    await NotificationService.cancel(id);
  }

  static Future<Map<String, int>> getStats() async {
    final db = await instance;
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    final pending = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM tasks WHERE is_completed = 0')) ??
        0;
    final overdue = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM tasks WHERE is_completed = 0 AND due_date < ?',
            [todayStr])) ??
        0;
    final todayTotal = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM tasks WHERE due_date = ?', [todayStr])) ??
        0;
    final todayDone = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM tasks WHERE due_date = ? AND is_completed = 1',
            [todayStr])) ??
        0;
    return {
      'pending': pending,
      'overdue': overdue,
      'todayTotal': todayTotal,
      'todayDone': todayDone,
    };
  }
}

// ---------------------------------------------------------------------------
// پوسته‌ها و تم‌های اختصاصی روزنگار
// ---------------------------------------------------------------------------
class AppThemes {
  static ThemeData atelier = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF11131A),
    primaryColor: const Color(0xFFA78BFA),
    cardColor: const Color(0xFF191C26),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFA78BFA),
      secondary: Color(0xFF66E0B5),
      error: Color(0xFFFF7A72),
      surface: Color(0xFF191C26),
    ),
    useMaterial3: true,
  );

  static ThemeData paper = ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF4F1EA),
    primaryColor: const Color(0xFF6352DE),
    cardColor: const Color(0xFFFFFFFF),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF6352DE),
      secondary: Color(0xFF198A65),
      error: Color(0xFFC95343),
      surface: Color(0xFFFFFFFF),
    ),
    useMaterial3: true,
  );

  static ThemeData signal = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0A0B0E),
    primaryColor: const Color(0xFFD6FF45),
    cardColor: const Color(0xFF141720),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFD6FF45),
      secondary: Color(0xFF45E0C0),
      error: Color(0xFFFF4D79),
      surface: Color(0xFF141720),
    ),
    useMaterial3: true,
  );
}

// ---------------------------------------------------------------------------
// تابع اصلی (Entry Point)
// ---------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const RooznegarApp());
}

class RooznegarApp extends StatefulWidget {
  const RooznegarApp({super.key});

  @override
  State<RooznegarApp> createState() => _RooznegarAppState();
}

class _RooznegarAppState extends State<RooznegarApp> {
  String _currentTheme = 'atelier';

  void _changeTheme(String themeName) {
    setState(() => _currentTheme = themeName);
  }

  ThemeData _getTheme() {
    switch (_currentTheme) {
      case 'paper':
        return AppThemes.paper;
      case 'signal':
        return AppThemes.signal;
      default:
        return AppThemes.atelier;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'روزنگار',
      debugShowCheckedModeBanner: false,
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _getTheme(),
      home: HomeScreen(
        currentTheme: _currentTheme,
        onThemeChanged: _changeTheme,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// صفحه اصلی (Home Screen)
// ---------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  final String currentTheme;
  final Function(String) onThemeChanged;

  const HomeScreen({
    super.key,
    required this.currentTheme,
    required this.onThemeChanged,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Task> _tasks = [];
  Map<String, int> _stats = {
    'pending': 0,
    'overdue': 0,
    'todayTotal': 0,
    'todayDone': 0
  };
  String _searchQuery = '';
  String _selectedCategory = 'همه';
  String _selectedPeriod = 'همه';
  bool _showCompleted = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final tasks = await AppDatabase.getTasks(
      query: _searchQuery,
      category: _selectedCategory,
      period: _selectedPeriod,
      showCompleted: _showCompleted,
    );
    final stats = await AppDatabase.getStats();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _stats = stats;
    });
  }

  String _formatJalali(String dateStr) {
    final d = DateTime.parse(dateStr);
    final j = Jalali.fromDateTime(d);
    return '${j.day} ${j.formatter.mN} ${j.year}';
  }

  String _toPersianDigits(String input) {
    const p = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    return input.replaceAllMapped(RegExp(r'\d'), (m) => p[int.parse(m[0]!)]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todayTotal = _stats['todayTotal'] ?? 0;
    final todayDone = _stats['todayDone'] ?? 0;
    final progress = todayTotal > 0 ? (todayDone / todayTotal) : 0.0;
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('روزنگار', style: TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: false,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.palette_outlined),
            onSelected: widget.onThemeChanged,
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: 'atelier', child: Text('آتلیه آرام (پیش‌فرض)')),
              const PopupMenuItem(
                  value: 'paper', child: Text('کاغذ روشن (Paper)')),
              const PopupMenuItem(
                  value: 'signal', child: Text('سیگنال نئونی (Signal)')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'خروجی فایل CSV',
            onPressed: _exportCSV,
          ),
        ],
      ),
      body: Column(
        children: [
          // کارت پیشرفت امروز
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('پیشرفت کارهای امروز',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 6),
                      Text(
                        _toPersianDigits(
                            '$todayDone از $todayTotal کار تکمیل شد'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor:
                              theme.dividerColor.withValues(alpha: 0.1),
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  _toPersianDigits('${(progress * 100).toInt()}٪'),
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
          // جستجو و فیلترها
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'جستجوی کارها...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                      filled: true,
                      fillColor: theme.cardColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) {
                      _searchQuery = val;
                      _refresh();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _selectedPeriod,
                  underline: const SizedBox(),
                  items: ['همه', 'امروز', 'عقب‌افتاده‌ها']
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedPeriod = v);
                    _refresh();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // لیست تسک‌ها
          Expanded(
            child: _tasks.isEmpty
                ? const Center(
                    child: Text('کاری برای نمایش وجود ندارد.',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _tasks.length,
                    itemBuilder: (context, i) {
                      final task = _tasks[i];
                      return Dismissible(
                        key: ValueKey(task.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 20),
                          color: Colors.redAccent,
                          child: const Icon(Icons.delete,
                              color: Colors.white),
                        ),
                        onDismissed: (_) async {
                          await AppDatabase.deleteTask(task.id!);
                          _refresh();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: theme.cardColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: theme.dividerColor
                                    .withValues(alpha: 0.08)),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                icon: Icon(
                                  task.isCompleted
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: task.isCompleted
                                      ? theme.colorScheme.secondary
                                      : Colors.grey,
                                ),
                                onPressed: () async {
                                  await AppDatabase.completeTask(task);
                                  _refresh();
                                },
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      task.title,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        decoration: task.isCompleted
                                            ? TextDecoration.lineThrough
                                            : null,
                                        color: task.isCompleted
                                            ? Colors.grey
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _toPersianDigits(
                                          '${task.category}  •  ${_formatJalali(task.dueDate)} ساعت ${task.dueTime}'),
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: theme.colorScheme.primary,
        onPressed: _openAddTaskModal,
        child: const Icon(Icons.add, color: Colors.black),
      ),
    );
  }

  void _openAddTaskModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => AddTaskSheet(onTaskAdded: _refresh),
    );
  }

  Future<void> _exportCSV() async {
    final tasks = await AppDatabase.getTasks(showCompleted: true);
    if (tasks.isEmpty) return;
    final buffer = StringBuffer();
    // ✅ اصلاح: افزودن BOM برای نمایش صحیح فارسی در اکسل + کوتیشن فیلدها
    buffer.write('\uFEFF');
    buffer.writeln('عنوان,دسته‌بندی,تاریخ شمسی,ساعت,اولویت,تکرار');
    for (var t in tasks) {
      // کوتیشن‌گذاری فیلدها برای جلوگیری از شکست CSV در صورت وجود کاما
      String q(String s) => '"${s.replaceAll('"', '""')}"';
      buffer.writeln(
          '${q(t.title)},${q(t.category)},${q(_formatJalali(t.dueDate))},${q(t.dueTime)},${q(t.priority)},${q(t.recurrence)}');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/rooznegar.csv');
    await file.writeAsString(buffer.toString());
    await Share.shareXFiles([XFile(file.path)], text: 'خروجی کارها از روزنگار');
  }
}

// ---------------------------------------------------------------------------
// فرم ثبت کار جدید (Bottom Sheet Modal)
// ---------------------------------------------------------------------------
class AddTaskSheet extends StatefulWidget {
  final VoidCallback onTaskAdded;
  const AddTaskSheet({super.key, required this.onTaskAdded});

  @override
  State<AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<AddTaskSheet> {
  final _titleController = TextEditingController();
  String _category = 'کاری';
  String _priority = 'متوسط';
  String _recurrence = 'بدون تکرار';
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  static const List<String> _categories = ['کاری', 'شخصی', 'تحصیلی', 'سلامتی', 'سایر'];
  static const List<String> _priorities = ['کم', 'متوسط', 'زیاد'];
  static const List<String> _recurrences = ['بدون تکرار', 'روزانه', 'هفتگی', 'ماهانه'];

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: 24,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('کار جدید',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          TextField(
            controller: _titleController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'عنوان کار...',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(Jalali.fromDateTime(_selectedDate).formatter.mN),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate,
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (d != null) setState(() => _selectedDate = d);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.access_time, size: 18),
                  label: Text(
                      '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}'),
                  onPressed: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: _selectedTime,
                    );
                    if (t != null) setState(() => _selectedTime = t);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ✅ اصلاح: افزودن انتخاب دسته، اولویت و تکرار که قبلاً غایب بود
          _buildDropdownRow('دسته', _category, _categories, (v) {
            if (v != null) setState(() => _category = v);
          }),
          const SizedBox(height: 10),
          _buildDropdownRow('اولویت', _priority, _priorities, (v) {
            if (v != null) setState(() => _priority = v);
          }),
          const SizedBox(height: 10),
          _buildDropdownRow('تکرار', _recurrence, _recurrences, (v) {
            if (v != null) setState(() => _recurrence = v);
          }),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _save,
              child: const Text('ثبت و فعال‌سازی یادآور',
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownRow(
    String label,
    String value,
    List<String> items,
    void Function(String?) onChanged,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
        ),
        Expanded(
          child: DropdownButtonFormField<String>(
            value: value,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            items: items
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  void _save() async {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('عنوان کار نمی‌تواند خالی باشد.')),
      );
      return;
    }
    final dateStr = _selectedDate.toIso8601String().substring(0, 10);
    final timeStr =
        '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}';
    final task = Task(
      title: _titleController.text.trim(),
      category: _category,
      dueDate: dateStr,
      dueTime: timeStr,
      priority: _priority,
      recurrence: _recurrence,
    );
    final id = await AppDatabase.insertTask(task);
    final alarmTime = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );
    await NotificationService.scheduleAlarm(
      id: id,
      title: 'یادآوری کار: ${task.title}',
      body: 'موعد انجام کار فرا رسیده است.',
      scheduledDate: alarmTime,
    );
    widget.onTaskAdded();
    if (mounted) Navigator.pop(context);
  }
}
