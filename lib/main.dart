import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(settings: initializationSettings);

  runApp(const LunaApp());
}

// ==========================================
// DATA MODELS
// ==========================================

class LunaAlarm {
  String id;
  String title;
  int hour;
  int minute;
  List<int> activeDays; // 1=Mon...7=Sun
  bool isActive;

  LunaAlarm({required this.id, required this.title, required this.hour, required this.minute, required this.activeDays, this.isActive = true});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'hour': hour, 'minute': minute, 'activeDays': activeDays, 'isActive': isActive};

  factory LunaAlarm.fromJson(Map<String, dynamic> json) => LunaAlarm(
    id: json['id'], title: json['title'] ?? 'Alarm', hour: json['hour'], minute: json['minute'], 
    activeDays: List<int>.from(json['activeDays'] ?? []), isActive: json['isActive'] ?? true
  );
}

class LunaTask {
  String id;
  String title;
  String content;
  DateTime startDate;
  DateTime endDate;
  String priority; // High, Medium, Low
  bool isCompleted;
  DateTime? lastCompletedDate;
  String? proofImagePath;

  LunaTask({required this.id, required this.title, required this.content, required this.startDate, required this.endDate, this.priority = 'Medium', this.isCompleted = false, this.lastCompletedDate, this.proofImagePath});

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'content': content, 'startDate': startDate.toIso8601String(), 'endDate': endDate.toIso8601String(), 
    'priority': priority, 'isCompleted': isCompleted, 'lastCompletedDate': lastCompletedDate?.toIso8601String(), 'proofImagePath': proofImagePath
  };

  factory LunaTask.fromJson(Map<String, dynamic> json) => LunaTask(
    id: json['id'], title: json['title'], content: json['content'], 
    startDate: json['startDate'] != null ? DateTime.parse(json['startDate']) : DateTime.now(), 
    endDate: json['endDate'] != null ? DateTime.parse(json['endDate']) : DateTime.now(), 
    priority: json['priority'] ?? 'Medium', isCompleted: json['isCompleted'] ?? false, 
    lastCompletedDate: json['lastCompletedDate'] != null ? DateTime.parse(json['lastCompletedDate']) : null, proofImagePath: json['proofImagePath']
  );
}

class LunaExpense {
  String id;
  String title;
  String description;
  double amount;
  DateTime dateAdded;

  LunaExpense({required this.id, required this.title, required this.description, required this.amount, required this.dateAdded});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'description': description, 'amount': amount, 'dateAdded': dateAdded.toIso8601String()};

  factory LunaExpense.fromJson(Map<String, dynamic> json) => LunaExpense(
    id: json['id'], title: json['title'] ?? 'Expense', description: json['description'] ?? '', amount: (json['amount'] as num).toDouble(), dateAdded: DateTime.parse(json['dateAdded'])
  );
}

// ==========================================
// NOTIFICATION SERVICE
// ==========================================

class NotificationService {
  static Future<void> requestPermissions() async {
    flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  static tz.TZDateTime _nextInstanceOfDayAndTime(int dayOfWeek, int hour, int minute) {
    tz.TZDateTime scheduledDate = _nextInstanceOfTime(hour, minute);
    while (scheduledDate.weekday != dayOfWeek) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  static tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (scheduledDate.isBefore(now)) scheduledDate = scheduledDate.add(const Duration(days: 1));
    return scheduledDate;
  }

  static Future<void> scheduleAlarm(LunaAlarm alarm) async {
    await cancelAlarm(alarm);
    if (!alarm.isActive || alarm.activeDays.isEmpty) return;

    for (int dayOfWeek in alarm.activeDays) {
      final scheduledDate = _nextInstanceOfDayAndTime(dayOfWeek, alarm.hour, alarm.minute);
      final notificationId = (alarm.id.hashCode + dayOfWeek).abs();

      await flutterLocalNotificationsPlugin.zonedSchedule(
        id: notificationId,
        title: alarm.title,
        body: 'Luna Alarm is ringing!',
        scheduledDate: scheduledDate,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('luna_alarms', 'Luna Alarms', importance: Importance.max, priority: Priority.high),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }
  }

  static Future<void> cancelAlarm(LunaAlarm alarm) async {
    for (int dayOfWeek in [1,2,3,4,5,6,7]) {
      final notificationId = (alarm.id.hashCode + dayOfWeek).abs();
      await flutterLocalNotificationsPlugin.cancel(id: notificationId);
    }
  }

  static Future<void> scheduleTaskReminders(LunaTask task) async {
    await cancelTaskReminders(task);
    if (task.isCompleted) return;

    final prefs = await SharedPreferences.getInstance();
    int intervalHours = 6;
    if (task.priority == 'High') intervalHours = prefs.getInt('pref_high_interval') ?? 1;
    else if (task.priority == 'Medium') intervalHours = prefs.getInt('pref_medium_interval') ?? 3;

    for (int i = 1; i <= 5; i++) {
      final scheduledDate = tz.TZDateTime.now(tz.local).add(Duration(hours: intervalHours * i));
      final notificationId = (task.id.hashCode + i).abs();
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id: notificationId,
        title: 'Task Reminder: ${task.title}',
        body: 'You have a pending task to complete.',
        scheduledDate: scheduledDate,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('luna_tasks', 'Luna Tasks', importance: Importance.max, priority: Priority.high),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  static Future<void> cancelTaskReminders(LunaTask task) async {
    for (int i = 1; i <= 5; i++) {
      final notificationId = (task.id.hashCode + i).abs();
      await flutterLocalNotificationsPlugin.cancel(id: notificationId);
    }
    await flutterLocalNotificationsPlugin.cancel(id: (task.id.hashCode + 999).abs());
  }

  static Future<void> snoozeTask(LunaTask task) async {
    final notificationId = (task.id.hashCode + 999).abs();
    final scheduledDate = tz.TZDateTime.now(tz.local).add(const Duration(hours: 2));
    await flutterLocalNotificationsPlugin.zonedSchedule(
      id: notificationId, title: 'Snoozed: ${task.title}', body: 'Time to complete this task!',
      scheduledDate: scheduledDate,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('luna_tasks', 'Luna Tasks', importance: Importance.max, priority: Priority.high),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }
}

// ==========================================
// MAIN APP & GLOBAL SHELL
// ==========================================

class LunaApp extends StatelessWidget {
  const LunaApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '🌙 Luna - An Indhu\'s Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Inter',
        appBarTheme: const AppBarTheme(elevation: 0, backgroundColor: Color(0xFF1E3A8A)),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({Key? key}) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 1; // 0=Alarms, 1=Tasks, 2=Expenses

  List<LunaAlarm> _alarms = [];
  List<LunaTask> _tasks = [];
  List<LunaExpense> _expenses = [];

  @override
  void initState() {
    super.initState();
    NotificationService.requestPermissions();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load Alarms
    final alarmsJson = prefs.getString('luna_alarms');
    if (alarmsJson != null) {
      _alarms = (jsonDecode(alarmsJson) as List).map((e) => LunaAlarm.fromJson(e)).toList();
    }
    
    // Load Tasks & Reset Day if needed
    final tasksJson = prefs.getString('luna_tasks');
    if (tasksJson != null) {
      _tasks = (jsonDecode(tasksJson) as List).map((e) => LunaTask.fromJson(e)).toList();
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      bool tasksNeedsSave = false;
      for (var task in _tasks) {
        if (task.isCompleted && task.lastCompletedDate != null) {
          final completedStr = DateFormat('yyyy-MM-dd').format(task.lastCompletedDate!);
          if (completedStr != todayStr) {
            task.isCompleted = false;
            task.lastCompletedDate = null;
            task.proofImagePath = null;
            tasksNeedsSave = true;
            NotificationService.scheduleTaskReminders(task);
          }
        }
      }
      if (tasksNeedsSave) _saveTasks();
    }

    // Load Expenses
    final expensesJson = prefs.getString('luna_expenses');
    if (expensesJson != null) {
      _expenses = (jsonDecode(expensesJson) as List).map((e) => LunaExpense.fromJson(e)).toList();
    }

    setState(() {});
  }

  Future<void> _saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('luna_alarms', jsonEncode(_alarms.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('luna_tasks', jsonEncode(_tasks.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveExpenses() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('luna_expenses', jsonEncode(_expenses.map((e) => e.toJson()).toList()));
  }

  void _showRainbowMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Create New", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildRainbowOption(
                      icon: Icons.access_alarms, label: 'Alarm', 
                      gradient: const LinearGradient(colors: [Color(0xFFFF416C), Color(0xFFFF4B2B)]),
                      onTap: () => _openEditor(0),
                    ),
                    _buildRainbowOption(
                      icon: Icons.check_circle_outline, label: 'Task', 
                      gradient: const LinearGradient(colors: [Color(0xFF2193b0), Color(0xFF6dd5ed)]),
                      onTap: () => _openEditor(1),
                    ),
                    _buildRainbowOption(
                      icon: Icons.attach_money, label: 'Expense', 
                      gradient: const LinearGradient(colors: [Color(0xFF11998e), Color(0xFF38ef7d)]),
                      onTap: () => _openEditor(2),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  Widget _buildRainbowOption({required IconData icon, required String label, required Gradient gradient, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: gradient,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: const Offset(0, 4))],
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
        ],
      ),
    );
  }

  void _openEditor(int type) async {
    Navigator.pop(context); // close bottom sheet
    dynamic result;
    
    if (type == 0) result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const AlarmEditorScreen()));
    if (type == 1) result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const TaskEditorScreen()));
    if (type == 2) result = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ExpenseEditorScreen()));

    if (result != null) {
      setState(() {
        if (result is LunaAlarm) {
          _alarms.add(result);
          NotificationService.scheduleAlarm(result);
          _saveAlarms();
          _currentIndex = 0;
        } else if (result is LunaTask) {
          _tasks.insert(0, result);
          if (!result.isCompleted) NotificationService.scheduleTaskReminders(result);
          _saveTasks();
          _currentIndex = 1;
        } else if (result is LunaExpense) {
          _expenses.insert(0, result);
          _saveExpenses();
          _currentIndex = 2;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: const Text('🌙 Luna - An Indhu\'s Assistant', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.assistant, color: Colors.white, size: 48),
                  SizedBox(height: 12),
                  Text('Luna Top Menus', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.access_alarms, color: Colors.pink),
              title: const Text('Alarms', style: TextStyle(fontSize: 16)),
              selected: _currentIndex == 0,
              onTap: () { 
                setState(() {
                  _currentIndex = 0;
                });
                Navigator.of(context).pop(); 
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: Colors.blue),
              title: const Text('Tasks & Habits', style: TextStyle(fontSize: 16)),
              selected: _currentIndex == 1,
              onTap: () { 
                setState(() {
                  _currentIndex = 1;
                });
                Navigator.of(context).pop(); 
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined, color: Colors.green),
              title: const Text('Expenses', style: TextStyle(fontSize: 16)),
              selected: _currentIndex == 2,
              onTap: () { 
                setState(() {
                  _currentIndex = 2;
                });
                Navigator.of(context).pop(); 
              },
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          AlarmsView(alarms: _alarms, onUpdate: () { _saveAlarms(); setState((){}); }),
          TasksView(tasks: _tasks, onUpdate: () { _saveTasks(); setState((){}); }),
          ExpensesView(expenses: _expenses, onUpdate: () { _saveExpenses(); setState((){}); }),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF1E3A8A),
        onPressed: _showRainbowMenu,
        child: const Icon(Icons.add, color: Colors.white, size: 32),
      ),
    );
  }
}

// ==========================================
// VIEWS (The 3 main contents)
// ==========================================

class AlarmsView extends StatelessWidget {
  final List<LunaAlarm> alarms;
  final VoidCallback onUpdate;

  const AlarmsView({Key? key, required this.alarms, required this.onUpdate}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (alarms.isEmpty) return const Center(child: Text("No alarms set.", style: TextStyle(color: Colors.grey, fontSize: 16)));
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: alarms.length,
      itemBuilder: (context, index) {
        final alarm = alarms[index];
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            onTap: () async {
              final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => AlarmEditorScreen(existing: alarm)));
              if (result != null) onUpdate();
            },
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          TimeOfDay(hour: alarm.hour, minute: alarm.minute).format(context),
                          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: alarm.isActive ? Colors.black87 : Colors.grey),
                        ),
                        const SizedBox(height: 4),
                        Text(alarm.title, style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 8),
                        Text(
                          alarm.activeDays.length == 7 ? 'Everyday' : 'Active: ${alarm.activeDays.length} days',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF1E3A8A), fontWeight: FontWeight.bold),
                        )
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Switch(
                        value: alarm.isActive,
                        activeColor: const Color(0xFF1E3A8A),
                        onChanged: (val) {
                          alarm.isActive = val;
                          if (val) NotificationService.scheduleAlarm(alarm);
                          else NotificationService.cancelAlarm(alarm);
                          onUpdate();
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () {
                          NotificationService.cancelAlarm(alarm);
                          alarms.removeAt(index);
                          onUpdate();
                        },
                      )
                    ],
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class TasksView extends StatelessWidget {
  final List<LunaTask> tasks;
  final VoidCallback onUpdate;
  final ImagePicker _picker = ImagePicker();

  TasksView({Key? key, required this.tasks, required this.onUpdate}) : super(key: key);

  List<LunaTask> _getActiveTasks() {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    return tasks.where((n) {
      final s = DateTime(n.startDate.year, n.startDate.month, n.startDate.day);
      final e = DateTime(n.endDate.year, n.endDate.month, n.endDate.day);
      return (today.isAtSameMomentAs(s) || today.isAfter(s)) && (today.isAtSameMomentAs(e) || today.isBefore(e));
    }).toList();
  }

  Future<void> _completeTaskWithProof(BuildContext context, LunaTask task) async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        task.proofImagePath = photo.path;
        task.isCompleted = true;
        task.lastCompletedDate = DateTime.now();
        await NotificationService.cancelTaskReminders(task);
        onUpdate();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeTasks = _getActiveTasks();
    if (activeTasks.isEmpty) return const Center(child: Text('No active tasks for today.', style: TextStyle(color: Colors.grey, fontSize: 16)));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: MasonryGridView.count(
        crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        itemCount: activeTasks.length,
        itemBuilder: (context, index) {
          final task = activeTasks[index];
          final pColor = task.priority == 'High' ? Colors.red : task.priority == 'Medium' ? Colors.orange : Colors.green;
          return GestureDetector(
            onTap: () async {
              final result = await Navigator.push(context, MaterialPageRoute(builder: (_) => TaskEditorScreen(existing: task)));
              if (result != null) onUpdate();
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: task.isCompleted ? Colors.grey[200]! : pColor.withOpacity(0.5), width: 2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (task.isCompleted && task.proofImagePath != null && File(task.proofImagePath!).existsSync())
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                      child: Image.file(File(task.proofImagePath!), height: 80, width: double.infinity, fit: BoxFit.cover),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!task.isCompleted) Container(margin: const EdgeInsets.only(bottom: 8), height: 4, width: 24, decoration: BoxDecoration(color: pColor, borderRadius: BorderRadius.circular(2))),
                        Text(task.title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, decoration: task.isCompleted ? TextDecoration.lineThrough : null, color: task.isCompleted ? Colors.grey : Colors.black87)),
                        const SizedBox(height: 12),
                        if (!task.isCompleted) Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(icon: const Icon(Icons.camera_alt, color: Colors.blue), onPressed: () => _completeTaskWithProof(context, task), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                            IconButton(icon: const Icon(Icons.snooze, color: Colors.orange), onPressed: () {
                              NotificationService.snoozeTask(task);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Snoozed for 2 hours.')));
                            }, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                          ],
                        ) else const Center(child: Icon(Icons.verified, color: Colors.green))
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ExpensesView extends StatelessWidget {
  final List<LunaExpense> expenses;
  final VoidCallback onUpdate;

  const ExpensesView({Key? key, required this.expenses, required this.onUpdate}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    double total = expenses.fold(0, (sum, item) => sum + item.amount);

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.green[700],
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: const Offset(0, 5))]
          ),
          child: Column(
            children: [
              const Text('TOTAL EXPENSES', style: TextStyle(color: Colors.white70, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('₹${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
        Expanded(
          child: expenses.isEmpty 
            ? const Center(child: Text("No expenses logged yet.", style: TextStyle(color: Colors.grey, fontSize: 16)))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: expenses.length,
                itemBuilder: (context, index) {
                  final exp = expenses[index];
                  return Card(
                    elevation: 1, margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const CircleAvatar(backgroundColor: Colors.green, child: Icon(Icons.currency_rupee, color: Colors.white)),
                      title: Text(exp.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${exp.description}\n${DateFormat('MMM d, yyyy - h:mm a').format(exp.dateAdded)}'),
                      isThreeLine: exp.description.isNotEmpty,
                      trailing: Text('₹${exp.amount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.redAccent)),
                      onLongPress: () {
                        expenses.removeAt(index);
                        onUpdate();
                      },
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }
}

// ==========================================
// FULL-SCREEN EDITORS
// ==========================================

class AlarmEditorScreen extends StatefulWidget {
  final LunaAlarm? existing;
  const AlarmEditorScreen({Key? key, this.existing}) : super(key: key);

  @override
  State<AlarmEditorScreen> createState() => _AlarmEditorScreenState();
}

class _AlarmEditorScreenState extends State<AlarmEditorScreen> {
  late TimeOfDay _selectedTime;
  late List<int> _activeDays;
  late TextEditingController _titleController;

  @override
  void initState() {
    super.initState();
    _selectedTime = widget.existing != null ? TimeOfDay(hour: widget.existing!.hour, minute: widget.existing!.minute) : TimeOfDay.now();
    _activeDays = widget.existing != null ? List.from(widget.existing!.activeDays) : [1,2,3,4,5,6,7];
    _titleController = TextEditingController(text: widget.existing?.title ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New Alarm' : 'Edit Alarm', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onTap: () async {
                  final picked = await showTimePicker(context: context, initialTime: _selectedTime);
                  if (picked != null) setState(() => _selectedTime = picked);
                },
                child: Text(
                  _selectedTime.format(context),
                  style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Alarm Title', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 24),
              const Text("Repeat Days", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: ['M', 'T', 'W', 'T', 'F', 'S', 'S'].asMap().entries.map((entry) {
                  final dayNum = entry.key + 1;
                  final isActive = _activeDays.contains(dayNum);
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (isActive) _activeDays.remove(dayNum);
                        else _activeDays.add(dayNum);
                      });
                    },
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: isActive ? const Color(0xFF1E3A8A) : Colors.grey[200],
                      child: Text(entry.value, style: TextStyle(color: isActive ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
                    ),
                  );
                }).toList(),
              ),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A), padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: () {
                  final alarm = widget.existing ?? LunaAlarm(
                    id: DateTime.now().millisecondsSinceEpoch.toString(), title: '', hour: 0, minute: 0, activeDays: []
                  );
                  alarm.title = _titleController.text.isEmpty ? 'Alarm' : _titleController.text;
                  alarm.hour = _selectedTime.hour;
                  alarm.minute = _selectedTime.minute;
                  alarm.activeDays = _activeDays;
                  Navigator.pop(context, alarm);
                },
                child: const Text('Save Alarm', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TaskEditorScreen extends StatefulWidget {
  final LunaTask? existing;
  const TaskEditorScreen({Key? key, this.existing}) : super(key: key);

  @override
  State<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<TaskEditorScreen> {
  late TextEditingController _titleCtrl;
  late TextEditingController _contentCtrl;
  late String _priority;
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.existing?.title ?? '');
    _contentCtrl = TextEditingController(text: widget.existing?.content ?? '');
    _priority = widget.existing?.priority ?? 'Medium';
    _startDate = widget.existing?.startDate ?? DateTime.now();
    _endDate = widget.existing?.endDate ?? DateTime.now();
  }

  void _pickDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context, initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2000), lastDate: DateTime(2101)
    );
    if (picked != null) {
      setState(() {
        if (isStart) { _startDate = picked; if (_endDate.isBefore(_startDate)) _endDate = _startDate; } 
        else { _endDate = picked; if (_startDate.isAfter(_endDate)) _startDate = _endDate; }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New Task' : 'Edit Task', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['Low', 'Medium', 'High'].map((p) {
                  final color = p == 'High' ? Colors.red : p == 'Medium' ? Colors.orange : Colors.green;
                  return ChoiceChip(
                    label: Text(p, style: TextStyle(color: _priority == p ? color : Colors.grey, fontWeight: FontWeight.bold)),
                    selected: _priority == p,
                    onSelected: (val) { if (val) setState(() => _priority = p); },
                    selectedColor: color.withOpacity(0.2),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _pickDate(true),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Start Date', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            Text(DateFormat('MMM d').format(_startDate), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _pickDate(false),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('End Date', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            Text(DateFormat('MMM d').format(_endDate), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              TextField(controller: _titleCtrl, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), decoration: const InputDecoration(hintText: 'Task Title', border: InputBorder.none)),
              TextField(controller: _contentCtrl, style: const TextStyle(fontSize: 16, height: 1.5), maxLines: null, decoration: const InputDecoration(hintText: 'Notes...', border: InputBorder.none)),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1E3A8A),
        label: const Text('Save Task', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        icon: const Icon(Icons.save, color: Colors.white),
        onPressed: () {
          if (_titleCtrl.text.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a task title.')));
            return;
          }
          final task = widget.existing ?? LunaTask(
            id: DateTime.now().millisecondsSinceEpoch.toString(), title: '', content: '', startDate: _startDate, endDate: _endDate
          );
          task.title = _titleCtrl.text;
          task.content = _contentCtrl.text;
          task.priority = _priority;
          task.startDate = _startDate;
          task.endDate = _endDate;
          Navigator.pop(context, task);
        },
      ),
    );
  }
}

class ExpenseEditorScreen extends StatefulWidget {
  const ExpenseEditorScreen({Key? key}) : super(key: key);

  @override
  State<ExpenseEditorScreen> createState() => _ExpenseEditorScreenState();
}

class _ExpenseEditorScreenState extends State<ExpenseEditorScreen> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();
  final TextEditingController _amtCtrl = TextEditingController();
  DateTime _selectedDate = DateTime.now();

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(context: context, initialDate: _selectedDate, firstDate: DateTime(2000), lastDate: DateTime(2101));
    if (date != null) {
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_selectedDate));
      if (time != null) {
        setState(() {
          _selectedDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('New Expense', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green[700],
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _amtCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.green),
                decoration: const InputDecoration(
                  prefixText: '₹ ', 
                  prefixStyle: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.green), 
                  hintText: '0.00',
                  border: InputBorder.none,
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _pickDateTime,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Icon(Icons.calendar_today, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      Text(DateFormat('MMM d, yyyy - h:mm a').format(_selectedDate), style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleCtrl, 
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(labelText: 'Title (e.g. Groceries)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _descCtrl, 
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(labelText: 'Description (Optional)', border: OutlineInputBorder()),
              ),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700], padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: () {
                  final amount = double.tryParse(_amtCtrl.text);
                  if (amount == null) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid amount.')));
                    return;
                  }
                  if (_titleCtrl.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a title.')));
                    return;
                  }
                  final exp = LunaExpense(
                    id: DateTime.now().millisecondsSinceEpoch.toString(), title: _titleCtrl.text, description: _descCtrl.text, amount: amount, dateAdded: _selectedDate
                  );
                  Navigator.pop(context, exp);
                },
                child: const Text('Save Expense', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
