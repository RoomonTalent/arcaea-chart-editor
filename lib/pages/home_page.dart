import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import 'song_management_page.dart';
import 'pack_management_page.dart';
import 'settings_page.dart';
import 'character_management_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.isLoading) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在初始化...'),
                ],
              ),
            );
          }

          if (!state.hasPath) {
            return const SettingsPage();
          }

          final pages = [
            const SongManagementPage(),
            const PackManagementPage(),
            const CharacterManagementPage(),
            const SettingsPage(),
          ];

          return Stack(
            children: [
              KeyedSubtree(
                key: ValueKey((
                  _currentIndex,
                  state.fileService.storage.identity,
                )),
                child: pages[_currentIndex],
              ),
              if (state.isScanning)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: Consumer<AppState>(
        builder: (context, state, _) {
          if (!state.hasPath) return const SizedBox.shrink();

          return NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) => setState(() => _currentIndex = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.music_note),
                selectedIcon: Icon(Icons.music_note, color: Color(0xFFB088F9)),
                label: '歌曲',
              ),
              NavigationDestination(
                icon: Icon(Icons.album),
                selectedIcon: Icon(Icons.album, color: Color(0xFFB088F9)),
                label: '曲包',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: '人物',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings),
                selectedIcon: Icon(Icons.settings, color: Color(0xFFB088F9)),
                label: '设置',
              ),
            ],
          );
        },
      ),
    );
  }
}
