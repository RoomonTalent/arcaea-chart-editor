import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arcaea_manager/services/arc_storage.dart';
import 'package:arcaea_manager/services/character_library.dart';
import 'package:arcaea_manager/services/gettext_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('人物导入中断会恢复被替换的文件，并清除已安装和待安装的新增文件', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('character-recovery-');
    addTearDown(() => dir.delete(recursive: true));
    final storage = ArcStorage(dir.path);
    await storage.createDirectory('char');
    final original = Uint8List.fromList([1]);
    final imported = Uint8List.fromList([2]);
    await storage.write('char/.arcaea-manager-original-123-1.png', original);
    await storage.write('char/1.png', imported);
    await storage.write('char/2.png', imported);
    await storage.write('char/.arcaea-manager-edit-123-3.png', imported);
    await storage.write(
      '.arcaea-character-import.json',
      utf8.encode(
        jsonEncode({
          'stamp': 123,
          'files': [
            {'path': 'char/1.png', 'exists': true},
            {'path': 'char/2.png', 'exists': false},
            {'path': 'char/3.png', 'exists': false},
          ],
        }),
      ),
    );
    await CharacterLibrary.open(storage);
    expect(await storage.read('char/1.png'), original);
    expect(await storage.kind('char/2.png'), isNull);
    expect(await storage.kind('char/3.png'), isNull);
    expect(await storage.kind('char/.arcaea-manager-edit-123-3.png'), isNull);
    expect(await storage.kind('.arcaea-character-import.json'), isNull);
  });

  test('人物包往返保留变体、语音、档案和选中的译文', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('character-transfer-');
    addTearDown(() => dir.delete(recursive: true));
    final exportParent = ArcStorage(dir.path);
    await exportParent.createDirectory('source');
    await exportParent.createDirectory('target');
    final source = exportParent.child('source');
    await source.createDirectory('char');
    await source.createDirectory('char/1080');
    await source.createDirectory('voice');
    await source.createDirectory('tl');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF0099FF), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 4);
    final buffer = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final portrait = Uint8List.sublistView(buffer);
    image.dispose();
    picture.dispose();
    await source.write('char/0_icon.png', portrait);
    await source.write('char/1_icon.png', portrait);
    await source.write('char/1080/0u.png', portrait);
    await source.write('voice/0_res_pm.ogg', Uint8List.fromList([1, 2, 3]));
    await source.write(
      'tl/zh-Hans.mo',
      GettextCatalog({'Hikari': '光', 'Other': '其他'}).encode(),
    );
    final library = await CharacterLibrary.open(source);
    await library.updateProfile('0u', {
      'alias': '觉醒光',
      'skill': 'gauge_easy',
      'offline': true,
    });
    final bundle = await library.exportCharacter(
      (await library.list()).first,
      dir.path,
    );
    final batch = ArcStorage(await library.exportCharacters({0, 1}, dir.path));
    expect(await batch.kind('0/char/1080/0u.png'), EntryKind.file);
    expect(await batch.kind('1/char/1_icon.png'), EntryKind.file);
    await exportParent.createDirectory('batch-target');
    final batchTarget = await CharacterLibrary.open(
      exportParent.child('batch-target'),
    );
    expect(
      await batchTarget.importCharacters({
        0: batch.child('0'),
        1: batch.child('1'),
      }, replaceExisting: {}),
      2,
    );
    await batchTarget.removeCharacters({0, 1});
    expect(await batchTarget.list(), isEmpty);
    expect(await batchTarget.root.kind('char/1_icon.png'), isNull);
    expect(
      (await batchTarget.root.list('char')).any(
        (entry) =>
            entry.name.startsWith('.arcaea-manager-removed-') &&
            entry.name.endsWith('-1_icon.png'),
      ),
      isTrue,
    );
    expect(await source.kind('char/1_icon.png'), EntryKind.file);
    expect(await source.read('char/1080/0u.png'), portrait);
    final target = await CharacterLibrary.open(exportParent.child('target'));
    expect(
      await target.importCharacter(ArcStorage(bundle), replaceExisting: false),
      0,
    );
    expect((await target.list()).map((asset) => asset.id), ['0', '0u']);
    expect(target.profile('0u')['alias'], '觉醒光');
    expect(target.profile('0u')['offline'], isTrue);
    expect(await target.root.read('voice/0_res_pm.ogg'), [1, 2, 3]);
    expect((await target.loadTranslations('zh-Hans'))!.messages['Hikari'], '光');
    expect(
      (await target.loadTranslations('zh-Hans'))!.messages,
      isNot(contains('Other')),
    );
    final oldPortrait = Uint8List.fromList([9, 8, 7]);
    await target.root.write('char/1080/0u.png', oldPortrait);
    await target.importCharacter(ArcStorage(bundle), replaceExisting: true);
    final backups = await target.root.list('char/1080');
    final backup = backups.singleWhere(
      (entry) => entry.name.startsWith('.arcaea-manager-original-'),
    );
    expect(await target.root.read('char/1080/${backup.name}'), oldPortrait);
    expect(await target.root.read('char/1080/0u.png'), portrait);
  });

  test('gettext preserves byte order, context and plural records', () {
    final source = {
      '': 'Content-Type: text/plain; charset=UTF-8\n',
      'Hikari': '光',
      'menu\u0004Name': '名称',
      'One\u0000Many': '一个\u0000多个',
    };
    for (final endian in [Endian.little, Endian.big]) {
      final parsed = GettextCatalog.decode(
        GettextCatalog(source, endian: endian).encode(),
      );
      expect(parsed.endian, endian);
      expect(parsed.messages, source);
    }
    expect(() => GettextCatalog.decode(Uint8List(4)), throwsFormatException);
  });

  test(
    'finds variant art, preserves other translations and keeps a restorable backup',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp(
        'arcaea-character-test-',
      );
      addTearDown(() async {
        final real = await dir.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (p.dirname(real) == temp &&
            p.basename(real).startsWith('arcaea-character-test-')) {
          await Directory(real).delete(recursive: true);
        }
      });
      final root = ArcStorage(dir.path);
      await root.createDirectory('char');
      await root.createDirectory('char/1080');
      await root.createDirectory('tl');
      await root.write('char/0u_icon.png', Uint8List(0));
      await root.write('char/0u.png', Uint8List(0));
      await root.write('char/1080/0u.png', Uint8List(0));
      await root.write('char/1080/0u_angry.png', Uint8List(0));
      await root.write('char/logo.png', Uint8List(0));
      final original = GettextCatalog({
        'Hikari': '光',
        'Another': '另外',
      }).encode();
      await root.write('tl/zh-Hans.mo', original);

      final library = await CharacterLibrary.open(root);
      final assets = await library.list();
      expect(assets.single.id, '0u');
      expect(assets.single.previewPaths.first, 'char/0u_icon.png');
      expect(assets.single.paths, hasLength(4));
      await library.updateTranslation('zh-Hans', 'Hikari', '测试名');
      expect((await library.loadTranslations('zh-Hans'))!.messages, {
        'Hikari': '测试名',
        'Another': '另外',
      });
      expect(await library.backups('tl/zh-Hans.mo'), hasLength(1));
      final oldest = (await library.backups('tl/zh-Hans.mo')).single;
      await library.updateTranslation('zh-Hans', 'Hikari', '又一个名称');
      await root.removeFile('tl/zh-Hans.mo');
      expect(await library.loadTranslations('zh-Hans'), isNull);
      await library.restore('tl/zh-Hans.mo', backup: oldest);
      expect(await root.read('tl/zh-Hans.mo'), original);

      final metadata = jsonEncode([
        {'character_id': 42, 'name': 'example', 'skill_id': 'existing'},
      ]);
      expect(
        await library.importReference(
          Uint8List.fromList(utf8.encode(metadata)),
        ),
        1,
      );
      await library.updateProfile('42', {
        'alias': '自定义名称',
        'skill': 'existing',
        'offline': false,
      });
      final reopened = await CharacterLibrary.open(root);
      expect(reopened.referenceName(42), 'example');
      expect(reopened.skills, contains('existing'));
      expect(reopened.profile('42')['offline'], isFalse);
    },
  );
}
