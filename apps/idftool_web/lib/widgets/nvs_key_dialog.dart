import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:idftool/idftool.dart';

import '../util/files.dart';

/// Ask for the HMAC key an encrypted NVS partition's keys are derived from.
/// With [image], the key has to decrypt it before the dialog accepts it.
Future<NvsKeys?> askNvsHmacKey(BuildContext context, {Uint8List? image}) =>
    showDialog<NvsKeys>(context: context, builder: (context) => _NvsKeyDialog(image: image));

class _NvsKeyDialog extends StatefulWidget {
  const _NvsKeyDialog({this.image});
  final Uint8List? image;

  @override
  State<_NvsKeyDialog> createState() => _NvsKeyDialogState();
}

class _NvsKeyDialogState extends State<_NvsKeyDialog> {
  final _key = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  /// [source] is typed hex or a key file's bytes.
  void _accept(Object source) {
    final NvsKeys keys;
    try {
      keys = NvsKeys.fromHmacKey(NvsKeys.parseHmacKey(source));
      if (widget.image case final image?) decryptNvs(image, keys);
    } on NvsError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.pop(context, keys);
  }

  Future<void> _loadFile() async {
    final file = await pickFile();
    if (file == null || !mounted) return;
    _accept(file.bytes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NVS HMAC key'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Encrypted NVS with HMAC key protection derives its encryption keys from the HMAC key burned into the chip\'s eFuse. '
              'Enter that key to read and edit the partition. It is kept in memory for this session only and never saved.'),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            autofocus: true,
            obscureText: _obscure,
            style: const TextStyle(fontFamily: 'RobotoMono'),
            decoration: InputDecoration(
              labelText: 'HMAC key (64 hex digits)',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show' : 'Hide',
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _accept(_key.text),
          ),
        ]),
      ),
      actions: [
        TextButton.icon(onPressed: _loadFile, icon: const Icon(Icons.folder_open), label: const Text('Key file…')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => _accept(_key.text), child: const Text('Use key')),
      ],
    );
  }
}
