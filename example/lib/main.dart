import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:polar/polar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart' as uuid;

void main() => runApp(const PolarExampleApp());

class PolarExampleApp extends StatelessWidget {
  const PolarExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const PolarTestBench(),
    );
  }
}

enum PolarConnectionState {
  disconnected,
  requesting,
  connecting,
  connected,
  disconnecting,
  restarting,
  factoryResetting,
}

class PolarTestBench extends StatefulWidget {
  const PolarTestBench({super.key});

  @override
  State<PolarTestBench> createState() => _PolarTestBenchState();
}

class _PolarTestBenchState extends State<PolarTestBench>
    with WidgetsBindingObserver {
  static const _deviceIdKey = 'polar.selectedDeviceId';
  static const _deviceNameKey = 'polar.selectedDeviceName';

  final _ble = FlutterReactiveBle();
  final _polar = Polar();
  final _devices = <String, DiscoveredDevice>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _streamSubscriptions = <PolarDataType, StreamSubscription<Object>>{};
  final _readyFeatures = <PolarSdkFeature>{};
  final _runningOperations = <String>{};
  final _results = <String, String>{};
  final _streamCounts = <PolarDataType, int>{};

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  var _bleStatus = BleStatus.unknown;
  var _connectionState = PolarConnectionState.disconnected;
  var _isScanning = false;
  var _restorePending = false;
  var _forgetAfterDisconnect = false;
  String? _selectedIdentifier;
  String? _selectedName;
  String? _sessionIdentifier;
  String? _error;
  Set<PolarDataType> _onlineDataTypes = {};
  Set<PolarDataType> _hrDataTypes = {};
  List<PolarExerciseEntry> _exercises = [];

  bool get _isConnected => _connectionState == PolarConnectionState.connected;

  bool get _isBusy =>
      _connectionState != PolarConnectionState.disconnected && !_isConnected;

  bool get _isPolar360 =>
      _selectedName?.toUpperCase().contains('POLAR 360') ?? false;

  String get _connectionLabel => switch (_connectionState) {
    PolarConnectionState.disconnected => 'Desligado',
    PolarConnectionState.requesting => 'Pedido de ligação enviado',
    PolarConnectionState.connecting => 'A ligar',
    PolarConnectionState.connected => 'Ligado',
    PolarConnectionState.disconnecting => 'A desligar',
    PolarConnectionState.restarting => 'Reinício solicitado',
    PolarConnectionState.factoryResetting => 'Factory reset solicitado',
  };

  String get _identifier =>
      _sessionIdentifier ??
      _selectedIdentifier ??
      (throw StateError('Nenhum dispositivo selecionado'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bleStatus = _ble.status;
    _listenToBleStatus();
    _listenToPolarEvents();
    unawaited(_restoreSelection());
  }

  void _listenToBleStatus() {
    _subscriptions.add(
      _ble.statusStream.listen((status) {
        if (!mounted) return;
        setState(() {
          _bleStatus = status;
          if (status != BleStatus.ready) _isScanning = false;
        });
        if (status != BleStatus.ready) {
          unawaited(_stopScan());
        } else if (_restorePending) {
          _restorePending = false;
          unawaited(_connect(restoring: true));
        }
      }, onError: (Object error) => _showError('Estado Bluetooth: $error')),
    );
  }

  void _listenToPolarEvents() {
    _subscriptions
      ..add(
        _polar.deviceConnecting.listen((device) {
          if (!_isCurrentConnection(device.deviceId)) return;
          _updateConnection(
            PolarConnectionState.connecting,
            sessionIdentifier: device.deviceId,
          );
        }, onError: (Object error) => _showError('Ligação: $error')),
      )
      ..add(
        _polar.deviceConnected.listen((device) {
          if (!_isCurrentConnection(device.deviceId)) return;
          _updateConnection(
            PolarConnectionState.connected,
            sessionIdentifier: device.deviceId,
          );
          _setResult('Ligação', 'Ligado: ${jsonEncode(device)}');
        }, onError: (Object error) => _showError('Ligação: $error')),
      )
      ..add(
        _polar.deviceDisconnected.listen((event) {
          if (!_isCurrentConnection(event.info.deviceId)) return;
          unawaited(_cancelAllStreams());
          if (!mounted) return;
          setState(() {
            _connectionState = PolarConnectionState.disconnected;
            _sessionIdentifier = null;
            _readyFeatures.clear();
            _onlineDataTypes = {};
            _hrDataTypes = {};
            if (_forgetAfterDisconnect) {
              _selectedIdentifier = null;
              _selectedName = null;
              _forgetAfterDisconnect = false;
            }
            if (event.pairingError) {
              _error = 'O SDK reportou um erro de emparelhamento.';
            }
          });
          _setResult(
            'Ligação',
            'Desligado: ${event.info.deviceId}; '
                'pairingError=${event.pairingError}',
          );
        }, onError: (Object error) => _showError('Desligação: $error')),
      )
      ..add(
        _polar.sdkFeatureReady.listen((event) {
          if (!_isCurrentConnection(event.identifier) || !mounted) return;
          setState(() => _readyFeatures.add(event.feature));
        }, onError: (Object error) => _showError('Funcionalidades: $error')),
      )
      ..add(
        _polar.disInformation.listen((event) {
          if (!_isCurrentConnection(event.identifier)) return;
          _setResult(
            'Informação do dispositivo',
            '${event.uuid}: ${event.info}',
          );
        }),
      )
      ..add(
        _polar.batteryLevel.listen((event) {
          if (!_isCurrentConnection(event.identifier)) return;
          _setResult('Bateria', '${event.level}%');
        }),
      )
      ..add(
        _polar.batteryChargingStatus.listen((event) {
          if (!_isCurrentConnection(event.identifier)) return;
          _setResult('Carregamento', event.chargingStatus.name);
        }),
      );
  }

  Future<void> _restoreSelection() async {
    final preferences = await SharedPreferences.getInstance();
    final identifier = preferences.getString(_deviceIdKey);
    if (identifier == null || !mounted) return;
    setState(() {
      _selectedIdentifier = identifier;
      _selectedName = preferences.getString(_deviceNameKey);
      _restorePending = true;
    });
    if (_ble.status == BleStatus.ready) {
      _restorePending = false;
      await _connect(restoring: true);
    }
  }

  Future<void> _persistSelection(String identifier, String deviceName) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_deviceIdKey, identifier);
    await preferences.setString(_deviceNameKey, deviceName);
  }

  Future<void> _clearSelection() async {
    if (_isConnected || _isBusy) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_deviceIdKey);
    await preferences.remove(_deviceNameKey);
    if (!mounted) return;
    setState(() {
      _selectedIdentifier = null;
      _selectedName = null;
      _error = null;
    });
  }

  bool _isCurrentConnection(String identifier) {
    if (_sessionIdentifier == identifier || _selectedIdentifier == identifier) {
      return true;
    }
    return _connectionState == PolarConnectionState.requesting ||
        _connectionState == PolarConnectionState.connecting ||
        _connectionState == PolarConnectionState.restarting;
  }

  void _updateConnection(
    PolarConnectionState state, {
    String? sessionIdentifier,
  }) {
    if (!mounted) return;
    setState(() {
      _connectionState = state;
      _sessionIdentifier = sessionIdentifier ?? _sessionIdentifier;
      _error = null;
    });
  }

  Future<void> _startScan() async {
    if (_isScanning || _isBusy) return;
    if (_isConnected) {
      _showError('Desliga o dispositivo antes de iniciar uma nova pesquisa.');
      return;
    }

    setState(() {
      _devices.clear();
      _error = null;
      _isScanning = true;
    });

    try {
      await _polar.requestPermissions();
      if (_ble.status != BleStatus.ready) {
        throw StateError('Bluetooth indisponível: ${_ble.status.name}');
      }
      await _scanSubscription?.cancel();
      _scanSubscription = _ble
          .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
          .listen(
            (device) {
              if (!mounted) return;
              setState(() => _devices[device.id] = device);
            },
            onError: (Object error) {
              if (!mounted) return;
              setState(() {
                _isScanning = false;
                _error = 'Pesquisa BLE: $error';
              });
            },
          );
    } catch (error) {
      await _stopScan();
      _showError('Não foi possível iniciar a pesquisa: $error');
    }
  }

  Future<void> _stopScan() async {
    final subscription = _scanSubscription;
    _scanSubscription = null;
    await subscription?.cancel();
    if (mounted && _isScanning) setState(() => _isScanning = false);
  }

  Future<void> _selectDevice(DiscoveredDevice device) async {
    if (_isBusy || _isConnected || !_isPolarDevice(device)) return;
    setState(() {
      _selectedIdentifier = device.id;
      _selectedName = device.name;
      _error = null;
    });
    await _persistSelection(device.id, device.name);
  }

  Future<void> _connect({bool restoring = false}) async {
    final identifier = _selectedIdentifier;
    if (identifier == null || _isBusy || _isConnected) return;
    await _stopScan();
    setState(() {
      _connectionState = PolarConnectionState.requesting;
      _sessionIdentifier = identifier;
      _readyFeatures.clear();
      _error = null;
    });
    _setResult(
      'Ligação',
      restoring
          ? 'A recuperar $identifier através de um novo pedido ao SDK'
          : 'Pedido enviado para $identifier',
    );

    try {
      await _polar.connectToDevice(identifier);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connectionState = PolarConnectionState.disconnected;
        _sessionIdentifier = null;
        _error = 'Pedido de ligação rejeitado: $error';
      });
    }
  }

  Future<void> _disconnect() async {
    if (_connectionState == PolarConnectionState.disconnected ||
        _connectionState == PolarConnectionState.disconnecting) {
      return;
    }
    await _cancelAllStreams();
    setState(() {
      _connectionState = PolarConnectionState.disconnecting;
      _error = null;
    });
    try {
      await _polar.disconnectFromDevice(_identifier);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connectionState = PolarConnectionState.disconnected;
        _sessionIdentifier = null;
        _readyFeatures.clear();
        _error = 'Não foi possível desligar: $error';
      });
    }
  }

  Future<void> _restartPolar360() async {
    if (!_isPolar360 || !_isConnected) return;
    await _runOperation('Restart Polar 360', () async {
      final ready =
          _readyFeatures.contains(PolarSdkFeature.deviceControl) ||
          await _polar.isFeatureReady(
            _identifier,
            PolarSdkFeature.deviceControl,
          );
      if (!ready) {
        throw StateError('deviceControl ainda não está pronto');
      }
      await _cancelAllStreams();
      setState(() => _connectionState = PolarConnectionState.restarting);
      try {
        await _polar.doRestart(_identifier);
      } catch (_) {
        if (mounted) {
          setState(() => _connectionState = PolarConnectionState.connected);
        }
        rethrow;
      }
      return 'Pedido aceite; a aguardar callback de desconexão. '
          'Isto não confirma que o dispositivo já reiniciou.';
    });
  }

  Future<void> _factoryResetPolar360() async {
    if (!_isPolar360 || !_isConnected) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover Polar 360?'),
        content: const Text(
          'Esta operação executa um factory reset e remove a informação de '
          'emparelhamento do dispositivo, permitindo configurá-lo noutro '
          'telemóvel. Os dados e configurações no dispositivo podem ser '
          'apagados. Não uses esta opção apenas para desligar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover e repor'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runOperation('Factory reset Polar 360', () async {
      final ready =
          _readyFeatures.contains(PolarSdkFeature.deviceControl) ||
          await _polar.isFeatureReady(
            _identifier,
            PolarSdkFeature.deviceControl,
          );
      if (!ready) {
        throw StateError('deviceControl ainda não está pronto');
      }

      await _cancelAllStreams();
      setState(() {
        _connectionState = PolarConnectionState.factoryResetting;
        _forgetAfterDisconnect = true;
      });
      try {
        await _polar.doFactoryReset(_identifier, false);
        final preferences = await SharedPreferences.getInstance();
        await preferences.remove(_deviceIdKey);
        await preferences.remove(_deviceNameKey);
      } catch (_) {
        if (mounted) {
          setState(() {
            _connectionState = PolarConnectionState.connected;
            _forgetAfterDisconnect = false;
          });
        }
        rethrow;
      }
      return 'Pedido aceite sem preservar pairing; a aguardar a '
          'desconexão. Isto não confirma que o reset terminou.';
    });
  }

  Future<void> _refreshDataTypes() async {
    await _runOperation('Tipos de streaming online', () async {
      final types = await _polar.getAvailableOnlineStreamDataTypes(_identifier);
      if (mounted) setState(() => _onlineDataTypes = types);
      return types.join(', ');
    });
    await _runOperation('Tipos de HR service', () async {
      final types = await _polar.getAvailableHrServiceDataTypes(_identifier);
      if (mounted) setState(() => _hrDataTypes = types);
      return types.join(', ');
    });
  }

  Stream<Object> _streamFor(PolarDataType type) => switch (type) {
    PolarDataType.hr => _polar.startHrStreaming(_identifier),
    PolarDataType.ecg => _polar.startEcgStreaming(_identifier),
    PolarDataType.acc => _polar.startAccStreaming(_identifier),
    PolarDataType.ppg => _polar.startPpgStreaming(_identifier),
    PolarDataType.ppi => _polar.startPpiStreaming(_identifier),
    PolarDataType.gyro => _polar.startGyroStreaming(_identifier),
    PolarDataType.magnetometer => _polar.startMagnetometerStreaming(
      _identifier,
    ),
    PolarDataType.temperature => _polar.startTemperatureStreaming(_identifier),
    PolarDataType.pressure => _polar.startPressureStreaming(_identifier),
    PolarDataType.skinTemperature => _polar.startSkinTemperatureStreaming(
      _identifier,
    ),
    PolarDataType.location => _polar.startLocationStreaming(_identifier),
  };

  Future<void> _startStream(PolarDataType type) async {
    if (_streamSubscriptions.containsKey(type)) return;
    try {
      final stream = _streamFor(type);
      final subscription = stream.listen(
        (data) {
          final count = (_streamCounts[type] ?? 0) + 1;
          if (!mounted) return;
          setState(() {
            _streamCounts[type] = count;
            _results['Stream ${type.name}'] =
                'Amostra $count — ${_encodeResult(data)}';
          });
        },
        onError: (Object error) {
          _setResult('Stream ${type.name}', 'ERRO: $error');
          unawaited(_stopStream(type));
        },
        onDone: () {
          _setResult('Stream ${type.name}', 'Concluído');
          unawaited(_stopStream(type));
        },
        cancelOnError: true,
      );
      setState(() {
        _streamSubscriptions[type] = subscription;
        _streamCounts[type] = 0;
        _results['Stream ${type.name}'] =
            'Iniciado às ${DateTime.now().toIso8601String()}';
      });
    } catch (error) {
      _setResult('Stream ${type.name}', 'ERRO: $error');
    }
  }

  Future<void> _stopStream(PolarDataType type) async {
    final subscription = _streamSubscriptions.remove(type);
    await subscription?.cancel();
    if (!mounted) return;
    setState(() {
      _results['Stream ${type.name}'] =
          'Parado após ${_streamCounts[type] ?? 0} amostras';
    });
  }

  Future<void> _cancelAllStreams() async {
    final subscriptions = _streamSubscriptions.values.toList();
    _streamSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshRecordingStatus() async {
    await _runOperation('Estado da gravação', () async {
      final status = await _polar.requestRecordingStatus(_identifier);
      return 'ongoing=${status.ongoing}; entryId=${status.entryId}';
    });
  }

  Future<void> _listExercises() async {
    await _runOperation('Listar exercícios', () async {
      final exercises = await _polar.listExercises(_identifier);
      if (mounted) setState(() => _exercises = exercises);
      return exercises.isEmpty
          ? 'Sem exercícios'
          : exercises.map(jsonEncode).join('\n');
    });
  }

  Future<void> _runFtu() async {
    await _runOperation('Executar FTU', () async {
      final config = PolarFirstTimeUseConfig(
        gender: FtuGender.male,
        birthDate: DateTime.utc(1990, 1, 1),
        height: 175,
        weight: 75,
        maxHeartRate: 190,
        vo2Max: 45,
        restingHeartRate: 60,
        trainingBackground: FtuTrainingBackground.occasional,
        sleepGoalMinutes: 480,
        typicalDay: FtuTypicalDay.mostlySitting,
        deviceTime: DateTime.now(),
      );
      await _polar.doFirstTimeUse(_identifier, config);
      return 'FTU enviado: ${jsonEncode(config)}';
    });
  }

  Future<void> _runOperation(
    String name,
    Future<Object?> Function() operation,
  ) async {
    if (_runningOperations.contains(name)) return;
    if (!_isConnected && name != 'Restart Polar 360') {
      _setResult(name, 'INDISPONÍVEL: dispositivo desligado');
      return;
    }
    setState(() {
      _runningOperations.add(name);
      _results[name] = 'Em execução desde ${DateTime.now().toIso8601String()}';
    });
    try {
      final result = await operation();
      _setResult(name, 'Concluído: ${_encodeResult(result)}');
    } catch (error) {
      _setResult(name, 'ERRO: $error');
    } finally {
      if (mounted) setState(() => _runningOperations.remove(name));
    }
  }

  String _encodeResult(Object? value) {
    if (value == null) return 'sem resultado';
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  void _setResult(String name, String result) {
    if (!mounted) return;
    setState(() => _results[name] = result);
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  void _clearResults() => setState(_results.clear);

  bool _isPolarDevice(DiscoveredDevice device) =>
      device.name.toUpperCase().contains('POLAR');

  bool _featureReady(PolarSdkFeature feature) =>
      _readyFeatures.contains(feature);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_stopScan());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_scanSubscription?.cancel());
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _streamSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList()
      ..sort((a, b) {
        final polarOrder = (_isPolarDevice(b) ? 1 : 0).compareTo(
          _isPolarDevice(a) ? 1 : 0,
        );
        return polarOrder != 0 ? polarOrder : b.rssi.compareTo(a.rssi);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Polar SDK Test Bench'),
        actions: [
          IconButton(
            tooltip: 'Limpar resultados',
            onPressed: _clearResults,
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _buildStatusCard(),
            _buildDiscovery(devices),
            if (_selectedIdentifier != null) _buildConnectionControls(),
            if (_isConnected) ...[
              _buildFeatures(),
              _buildDeviceInformation(),
              _buildStreams(),
              _buildRecording(),
              _buildDeviceControl(),
              _buildFtu(),
            ],
            _buildResults(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bluetooth: ${_bleStatus.name}'),
            Text('Sessão Polar: $_connectionLabel'),
            Text('Nome guardado: ${_selectedName ?? "nenhum"}'),
            Text('Identificador guardado: ${_selectedIdentifier ?? "nenhum"}'),
            if (_sessionIdentifier != null)
              Text('Identificador da sessão: $_sessionIdentifier'),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscovery(List<DiscoveredDevice> devices) {
    return ExpansionTile(
      initiallyExpanded: _selectedIdentifier == null,
      title: const Text('Descoberta BLE'),
      subtitle: Text(_isScanning ? 'Pesquisa em curso' : 'Pesquisa parada'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isScanning ? _stopScan : _startScan,
                  icon: Icon(_isScanning ? Icons.stop : Icons.search),
                  label: Text(_isScanning ? 'Parar' : 'Pesquisar'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed:
                    _selectedIdentifier != null && !_isBusy && !_isConnected
                    ? _clearSelection
                    : null,
                child: const Text('Esquecer'),
              ),
            ],
          ),
        ),
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nenhum resultado. A pesquisa não cria ligações BLE.'),
          )
        else
          ...devices.map((device) {
            final isPolar = _isPolarDevice(device);
            final selected = _selectedIdentifier == device.id;
            return ListTile(
              selected: selected,
              enabled: isPolar && !_isBusy && !_isConnected,
              onTap: () => _selectDevice(device),
              leading: Icon(
                selected
                    ? Icons.radio_button_checked
                    : isPolar
                    ? Icons.watch
                    : Icons.bluetooth,
              ),
              title: Text(
                device.name.isEmpty ? 'Dispositivo sem nome' : device.name,
              ),
              subtitle: Text('${device.id}\nRSSI: ${device.rssi} dBm'),
              isThreeLine: true,
            );
          }),
      ],
    );
  }

  Widget _buildConnectionControls() {
    return ExpansionTile(
      initiallyExpanded: true,
      title: const Text('Ligação Polar SDK'),
      subtitle: Text(_connectionLabel),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _connectionState == PolarConnectionState.disconnected
                    ? _connect
                    : null,
                icon: const Icon(Icons.bluetooth_connected),
                label: const Text('Ligar'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _connectionState != PolarConnectionState.disconnected &&
                        _connectionState != PolarConnectionState.disconnecting
                    ? _disconnect
                    : null,
                icon: const Icon(Icons.link_off),
                label: const Text('Desligar'),
              ),
              if (_isPolar360)
                OutlinedButton.icon(
                  onPressed: _isConnected ? _restartPolar360 : null,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reiniciar 360'),
                ),
              if (_isPolar360)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: _isConnected ? _factoryResetPolar360 : null,
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Remover 360'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatures() {
    return ExpansionTile(
      title: const Text('Readiness de funcionalidades'),
      subtitle: Text('${_readyFeatures.length} prontas'),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: PolarSdkFeature.values.map((feature) {
              final ready = _readyFeatures.contains(feature);
              return Chip(
                avatar: Icon(
                  ready ? Icons.check_circle : Icons.hourglass_empty,
                  size: 18,
                ),
                label: Text(
                  '${feature.name}: ${ready ? "pronta" : "não pronta"}',
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceInformation() {
    return ExpansionTile(
      title: const Text('Informação e capacidades'),
      children: [
        _OperationButton(
          label: 'Consultar tipos de dados',
          running: _runningOperations.contains('Tipos de streaming online'),
          onPressed: _refreshDataTypes,
        ),
        const ListTile(
          title: Text('DIS, bateria e carregamento'),
          subtitle: Text(
            'São atualizados pelos callbacks do SDK e apresentados em Resultados.',
          ),
        ),
      ],
    );
  }

  Widget _buildStreams() {
    final available = {..._onlineDataTypes, ..._hrDataTypes}.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return ExpansionTile(
      title: const Text('Streaming'),
      subtitle: Text(
        available.isEmpty
            ? 'Consulta primeiro os tipos disponíveis'
            : '${available.length} tipos disponíveis',
      ),
      children: [
        if (!_featureReady(PolarSdkFeature.onlineStreaming) &&
            !_featureReady(PolarSdkFeature.hr))
          const ListTile(
            title: Text('Feature ainda não pronta'),
            subtitle: Text('Aguarda onlineStreaming ou HR.'),
          ),
        for (final type in available)
          ListTile(
            title: Text(type.name),
            subtitle: Text(
              _streamSubscriptions.containsKey(type)
                  ? 'Em execução — ${_streamCounts[type] ?? 0} amostras'
                  : 'Parado',
            ),
            trailing: _streamSubscriptions.containsKey(type)
                ? IconButton(
                    tooltip: 'Parar',
                    onPressed: () => _stopStream(type),
                    icon: const Icon(Icons.stop),
                  )
                : IconButton(
                    tooltip: 'Iniciar',
                    onPressed: () => _startStream(type),
                    icon: const Icon(Icons.play_arrow),
                  ),
          ),
        if (_streamSubscriptions.isNotEmpty)
          _OperationButton(
            label: 'Parar todos os streams',
            onPressed: _cancelAllStreams,
          ),
      ],
    );
  }

  Widget _buildRecording() {
    final recordingReady = _featureReady(PolarSdkFeature.h10ExerciseRecording);
    final fileTransferReady = _featureReady(PolarSdkFeature.fileTransfer);
    return ExpansionTile(
      title: const Text('Recording e exercícios'),
      subtitle: Text(
        recordingReady || fileTransferReady
            ? 'Operações disponíveis'
            : 'Não suportadas ou não prontas',
      ),
      children: [
        ListTile(
          title: const Text('Gravação H10'),
          subtitle: Text(
            recordingReady ? 'Feature pronta' : 'Não suportada ou não pronta',
          ),
        ),
        if (!recordingReady)
          const ListTile(
            subtitle: Text(
              'Requer h10ExerciseRecording pronta; normalmente Polar H10.',
            ),
          )
        else ...[
          _OperationButton(
            label: 'Iniciar gravação RR',
            running: _runningOperations.contains('Iniciar gravação'),
            onPressed: () => _runOperation('Iniciar gravação', () async {
              final exerciseId = const uuid.Uuid().v4();
              await _polar.startRecording(
                _identifier,
                exerciseId: exerciseId,
                interval: RecordingInterval.interval_1s,
                sampleType: SampleType.rr,
              );
              return 'exerciseId=$exerciseId';
            }),
          ),
          _OperationButton(
            label: 'Parar gravação',
            running: _runningOperations.contains('Parar gravação'),
            onPressed: () => _runOperation('Parar gravação', () async {
              await _polar.stopRecording(_identifier);
              return null;
            }),
          ),
          _OperationButton(
            label: 'Consultar estado',
            running: _runningOperations.contains('Estado da gravação'),
            onPressed: _refreshRecordingStatus,
          ),
        ],
        ListTile(
          title: const Text('Exercícios armazenados'),
          subtitle: Text(
            fileTransferReady
                ? 'File transfer pronta'
                : 'Não suportado ou não pronto',
          ),
        ),
        if (!fileTransferReady)
          const ListTile(
            subtitle: Text(
              'Listar, obter e remover requer fileTransfer pronta.',
            ),
          )
        else ...[
          _OperationButton(
            label: 'Listar exercícios',
            running: _runningOperations.contains('Listar exercícios'),
            onPressed: _listExercises,
          ),
          for (final entry in _exercises)
            ListTile(
              title: Text(entry.entryId),
              subtitle: Text(entry.path),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: 'Obter',
                    onPressed: () => _runOperation(
                      'Obter exercício ${entry.entryId}',
                      () => _polar.fetchExercise(_identifier, entry),
                    ),
                    icon: const Icon(Icons.download),
                  ),
                  IconButton(
                    tooltip: 'Remover',
                    onPressed: () => _runOperation(
                      'Remover exercício ${entry.entryId}',
                      () async {
                        await _polar.removeExercise(_identifier, entry);
                        await _listExercises();
                        return null;
                      },
                    ),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildDeviceControl() {
    final sdkModeReady = _featureReady(PolarSdkFeature.sdkMode);
    final ledReady = _featureReady(PolarSdkFeature.ledAnimation);
    return ExpansionTile(
      title: const Text('Configuração e controlo'),
      children: [
        ListTile(
          title: const Text('SDK mode'),
          subtitle: Text(
            sdkModeReady ? 'Feature pronta' : 'Não suportada ou não pronta',
          ),
        ),
        if (sdkModeReady) ...[
          _OperationButton(
            label: 'Consultar SDK mode',
            onPressed: () => _runOperation(
              'Estado SDK mode',
              () => _polar.isSdkModeEnabled(_identifier),
            ),
          ),
          _OperationButton(
            label: 'Ativar SDK mode',
            onPressed: () => _runOperation('Ativar SDK mode', () async {
              await _polar.enableSdkMode(_identifier);
              return null;
            }),
          ),
          _OperationButton(
            label: 'Desativar SDK mode',
            onPressed: () => _runOperation('Desativar SDK mode', () async {
              await _polar.disableSdkMode(_identifier);
              return null;
            }),
          ),
        ],
        ListTile(
          title: const Text('LED'),
          subtitle: Text(
            ledReady ? 'Feature pronta' : 'Não suportada ou não pronta',
          ),
        ),
        if (ledReady)
          _OperationButton(
            label: 'Testar configuração LED',
            onPressed: () => _runOperation('Configuração LED', () async {
              await _polar.setLedConfig(
                _identifier,
                const LedConfig(
                  ppiModeLedEnabled: true,
                  sdkModeLedEnabled: true,
                ),
              );
              return 'LEDs ativados para PPI/SDK mode';
            }),
          ),
        ListTile(
          title: const Text('Factory reset'),
          subtitle: Text(
            _isPolar360
                ? 'Disponível em “Remover 360”, com confirmação explícita.'
                : 'Operação destrutiva não disponibilizada para este dispositivo.',
          ),
        ),
      ],
    );
  }

  Widget _buildFtu() {
    final ready = _featureReady(PolarSdkFeature.deviceTimeSetup);
    return ExpansionTile(
      title: const Text('First Time Use'),
      subtitle: Text(ready ? 'Feature pronta' : 'Não suportada ou não pronta'),
      children: [
        if (!ready)
          const ListTile(
            title: Text('Indisponível'),
            subtitle: Text('Requer deviceTimeSetup pronta.'),
          )
        else ...[
          _OperationButton(
            label: 'Consultar estado FTU',
            onPressed: () => _runOperation(
              'Estado FTU',
              () => _polar.isFtuDone(_identifier),
            ),
          ),
          _OperationButton(
            label: 'Executar FTU com dados de teste',
            running: _runningOperations.contains('Executar FTU'),
            onPressed: _runFtu,
          ),
          const ListTile(
            title: Text('Atenção'),
            subtitle: Text(
              'FTU é manual. Os dados de teste estão visíveis no resultado.',
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResults() {
    return ExpansionTile(
      initiallyExpanded: true,
      title: const Text('Resultados e diagnóstico'),
      subtitle: Text('${_results.length} operações/eventos'),
      children: [
        if (_results.isEmpty)
          const ListTile(title: Text('Sem resultados'))
        else
          ..._results.entries.toList().reversed.map(
            (entry) => ListTile(
              title: Text(entry.key),
              subtitle: SelectableText(entry.value),
            ),
          ),
      ],
    );
  }
}

class _OperationButton extends StatelessWidget {
  const _OperationButton({
    required this.label,
    required this.onPressed,
    this.running = false,
  });

  final String label;
  final Future<void> Function() onPressed;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: running
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'Executar',
              onPressed: onPressed,
              icon: const Icon(Icons.play_arrow),
            ),
    );
  }
}
