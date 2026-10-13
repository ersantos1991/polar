package dev.rexios.polar

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.google.gson.GsonBuilder
import com.google.gson.JsonDeserializationContext
import com.google.gson.JsonDeserializer
import com.google.gson.JsonElement
import com.google.gson.JsonPrimitive
import com.google.gson.JsonSerializationContext
import com.google.gson.JsonSerializer
import com.polar.androidcommunications.api.ble.model.DisInfo
import com.polar.androidcommunications.api.ble.model.gatt.client.ChargeState
import com.polar.androidcommunications.api.ble.model.gatt.client.PowerSourcesState
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApi.PolarBleSdkFeature
import com.polar.sdk.api.PolarBleApi.PolarDeviceDataType
import com.polar.sdk.api.PolarBleApiCallbackProvider
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.PolarH10OfflineExerciseApi.RecordingInterval
import com.polar.sdk.api.PolarH10OfflineExerciseApi.SampleType
import com.polar.sdk.api.model.LedConfig
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarExerciseEntry
import com.polar.sdk.api.model.PolarFirstTimeUseConfig
import com.polar.sdk.api.model.PolarHealthThermometerData
import com.polar.sdk.api.model.PolarHrData
import com.polar.sdk.api.model.PolarSensorSetting
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.FlutterLifecycleAdapter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import java.lang.reflect.Type
import java.time.Instant
import java.time.LocalDate
import java.util.Collections
import java.util.Date
import java.util.UUID

object DateSerializer : JsonDeserializer<Date>, JsonSerializer<Date> {
    override fun deserialize(
        json: JsonElement?,
        typeOfT: Type?,
        context: JsonDeserializationContext?,
    ): Date {
        if (json == null || json.isJsonNull) {
            return Date(0)
        }

        val primitive = json.asJsonPrimitive
        return when {
            primitive.isNumber -> Date(primitive.asLong)
            primitive.isString -> Date.from(Instant.parse(primitive.asString))
            else -> throw IllegalArgumentException("Unsupported date payload: $json")
        }
    }

    override fun serialize(
        src: LocalDateTime?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?,
    ): JsonElement =
        JsonPrimitive(
            src?.toInstant(ZoneOffset.UTC)?.toEpochMilli() ?: 0,
        )
}

object LocalDateSerializer : JsonDeserializer<LocalDate>, JsonSerializer<LocalDate> {
    override fun deserialize(
        json: JsonElement?,
        typeOfT: Type?,
        context: JsonDeserializationContext?,
    ): LocalDate {
        if (json == null || json.isJsonNull) {
            throw IllegalArgumentException("LocalDate payload was null")
        }

        if (json.isJsonPrimitive) {
            return LocalDate.parse(json.asString)
        }

        val obj = json.asJsonObject
        val year =
            obj.get("year")?.asInt
                ?: obj.get("yearValue")?.asInt
                ?: throw IllegalArgumentException("Missing year in LocalDate payload: $json")
        val month =
            obj.get("month")?.asInt
                ?: obj.get("monthValue")?.asInt
                ?: throw IllegalArgumentException("Missing month in LocalDate payload: $json")
        val day =
            obj.get("day")?.asInt
                ?: obj.get("dayOfMonth")?.asInt
                ?: throw IllegalArgumentException("Missing day in LocalDate payload: $json")

        return LocalDate.of(year, month, day)
    }

    override fun serialize(
        src: LocalDate?,
        typeOfSrc: Type?,
        context: JsonSerializationContext?,
    ): JsonElement {
        val value = src ?: return JsonPrimitive(null as String?)
        val obj = com.google.gson.JsonObject()
        obj.addProperty("year", value.year)
        obj.addProperty("month", value.monthValue)
        obj.addProperty("day", value.dayOfMonth)
        return obj
    }
}

private fun runOnUiThread(runnable: () -> Unit) {
    Handler(Looper.getMainLooper()).post { runnable() }
}

private val gson =
    GsonBuilder()
        .registerTypeAdapter(Date::class.java, DateSerializer)
        .registerTypeAdapter(LocalDate::class.java, LocalDateSerializer)
        .create()

private var wrapperInternal: PolarWrapper? = null
private val wrapper: PolarWrapper
    get() = wrapperInternal!!

/** PolarPlugin */
class PolarPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {
    // Binary messenger for dynamic EventChannel registration
    private lateinit var messenger: BinaryMessenger

    // Method channel
    private lateinit var methodChannel: MethodChannel

    // Event channel
    private lateinit var eventChannel: EventChannel

    // Search channel
    private lateinit var searchChannel: EventChannel

    // Context
    private lateinit var context: Context

    // Streaming channels
    private val streamingChannels = mutableMapOf<String, StreamingChannel>()

    private var attachedToEngine = false
    private var operationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val operationJobs = Collections.synchronizedSet(mutableSetOf<Job>())
    private val sinkIds = mutableSetOf<Int>()
    private var activityLifecycle: Lifecycle? = null
    private val lifecycleObserver =
        LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                wrapperInternal?.api?.foregroundEntered()
            }
        }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = true
        if (!operationScope.coroutineContext[Job]!!.isActive) {
            operationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        }
        messenger = flutterPluginBinding.binaryMessenger

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "polar/methods")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "polar/events")
        eventChannel.setStreamHandler(this)

        searchChannel = EventChannel(flutterPluginBinding.binaryMessenger, "polar/search")
        searchChannel.setStreamHandler(searchHandler)

        context = flutterPluginBinding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = false
        operationScope.cancel()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        searchChannel.setStreamHandler(null)
        streamingChannels.values.forEach { it.dispose() }
        streamingChannels.clear()
        sinkIds.forEach { wrapperInternal?.removeSink(it) }
        sinkIds.clear()
        detachLifecycle()
        shutDown()
    }

    private fun initApi() {
        if (wrapperInternal == null) {
            wrapperInternal = PolarWrapper(context)
        }
    }

    private fun launchOperation(
        result: Result,
        operation: suspend () -> Any?,
    ) {
        lateinit var job: Job
        job =
            operationScope.launch(start = CoroutineStart.LAZY) {
                try {
                    val value = operation()
                    completeResult { result.success(value) }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    completeResult { result.error(error.toString(), error.message, null) }
                } finally {
                    operationJobs.remove(job)
                }
            }
        operationJobs.add(job)
        job.start()
    }

    private fun completeResult(completion: () -> Unit) {
        if (!attachedToEngine) return
        runOnUiThread {
            if (attachedToEngine) {
                completion()
            }
        }
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        initApi()

        try {
            when (call.method) {
                "connectToDevice" -> {
                    wrapper.api.connectToDevice(call.arguments as String)
                    result.success(null)
                }
                "waitForConnection" -> {
                    launchOperation(result) {
                        wrapper.api.waitForConnection(call.arguments as String)
                        null
                    }
                }
                "setAutomaticReconnection" -> {
                    wrapper.api.setAutomaticReconnection(call.arguments as Boolean)
                    result.success(null)
                }
                "disconnectFromDevice" -> {
                    wrapper.api.disconnectFromDevice(call.arguments as String)
                    result.success(null)
                }

                "getAvailableOnlineStreamDataTypes" -> {
                    getAvailableOnlineStreamDataTypes(call, result)
                }

                "getAvailableHrServiceDataTypes" -> {
                    getAvailableHrServiceDataTypes(call, result)
                }

                "requestStreamSettings" -> {
                    requestStreamSettings(call, result)
                }

                "createStreamingChannel" -> {
                    createStreamingChannel(call, result)
                }

                "startRecording" -> {
                    startRecording(call, result)
                }

                "stopRecording" -> {
                    stopRecording(call, result)
                }

                "requestRecordingStatus" -> {
                    requestRecordingStatus(call, result)
                }

                "listExercises" -> {
                    listExercises(call, result)
                }

                "fetchExercise" -> {
                    fetchExercise(call, result)
                }

                "removeExercise" -> {
                    removeExercise(call, result)
                }

                "setLedConfig" -> {
                    setLedConfig(call, result)
                }

                "doFactoryReset" -> {
                    doFactoryReset(call, result)
                }

                "doRestart" -> {
                    doRestart(call, result)
                }

                "isFeatureReady" -> {
                    isFeatureReady(call, result)
                }

                "enableSdkMode" -> {
                    enableSdkMode(call, result)
                }

                "disableSdkMode" -> {
                    disableSdkMode(call, result)
                }

                "isSdkModeEnabled" -> {
                    isSdkModeEnabled(call, result)
                }

                "doFirstTimeUse" -> {
                    doFirstTimeUse(call, result)
                }

                "isFtuDone" -> {
                    isFtuDone(call, result)
                }

                else -> {
                    result.notImplemented()
                }
            }
        } catch (error: Throwable) {
            result.error(error.toString(), error.message, null)
        }
    }

    override fun onListen(
        arguments: Any?,
        events: EventSink,
    ) {
        initApi()
        val id = arguments as Int
        sinkIds.add(id)
        wrapper.addSink(id, events)
    }

    override fun onCancel(arguments: Any?) {
        val id = arguments as? Int ?: return
        sinkIds.remove(id)
        wrapper.removeSink(id)
    }

    private val searchHandler =
        object : EventChannel.StreamHandler {
            private var searchJob: Job? = null

            override fun onListen(
                arguments: Any?,
                events: EventSink,
            ) {
                initApi()
                searchJob?.cancel()
                searchJob =
                    operationScope.launch {
                        try {
                            wrapper.api.searchForDevice().collect {
                                completeResult { events.success(gson.toJson(it)) }
                            }
                            completeResult { events.endOfStream() }
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Throwable) {
                            completeResult { events.error(error.toString(), error.message, null) }
                        }
                    }
            }

            override fun onCancel(arguments: Any?) {
                searchJob?.cancel()
                searchJob = null
            }
        }

    private fun createStreamingChannel(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val name = arguments[0] as String
        val identifier = arguments[1] as String
        val feature = gson.fromJson(arguments[2] as String, PolarDeviceDataType::class.java)

        if (streamingChannels[name] == null) {
            streamingChannels[name] =
                StreamingChannel(messenger, name, wrapper.api, identifier, feature)
        }

        result.success(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachLifecycle(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachLifecycle()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachLifecycle(binding)
    }

    override fun onDetachedFromActivity() {
        detachLifecycle()
    }

    private fun attachLifecycle(binding: ActivityPluginBinding) {
        detachLifecycle()
        activityLifecycle = FlutterLifecycleAdapter.getActivityLifecycle(binding)
        activityLifecycle?.addObserver(lifecycleObserver)
    }

    private fun detachLifecycle() {
        activityLifecycle?.removeObserver(lifecycleObserver)
        activityLifecycle = null
    }

    private fun shutDown() {
        val currentWrapper = wrapperInternal ?: return
        if (currentWrapper.shutDown()) {
            wrapperInternal = null
        }
    }

    private fun getAvailableOnlineStreamDataTypes(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            val dataTypes =
                wrapper.api
                    .getAvailableOnlineStreamDataTypes(identifier)
                    .filterNot { it == PolarDeviceDataType.DERIVED_MEASUREMENT }
                    .toSet()
            gson.toJson(dataTypes)
        }
    }

    private fun getAvailableHrServiceDataTypes(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            val dataTypes =
                wrapper.api
                    .getAvailableHRServiceDataTypes(identifier)
                    .filterNot { it == PolarDeviceDataType.DERIVED_MEASUREMENT }
                    .toSet()
            gson.toJson(dataTypes)
        }
    }

    private fun requestStreamSettings(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val feature = gson.fromJson(arguments[1] as String, PolarDeviceDataType::class.java)

        launchOperation(result) {
            gson.toJson(wrapper.api.requestStreamSettings(identifier, feature))
        }
    }

    private fun startRecording(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val exerciseId = arguments[1] as String
        val interval = gson.fromJson(arguments[2] as String, RecordingInterval::class.java)
        val sampleType = gson.fromJson(arguments[3] as String, SampleType::class.java)

        launchOperation(result) {
            wrapper.api.startRecording(identifier, exerciseId, interval, sampleType)
            null
        }
    }

    private fun stopRecording(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String

        launchOperation(result) {
            wrapper.api.stopRecording(identifier)
            null
        }
    }

    private fun requestRecordingStatus(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String

        launchOperation(result) {
            val status = wrapper.api.requestRecordingStatus(identifier)
            listOf(status.ongoing, status.entryId)
        }
    }

    private fun listExercises(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String

        launchOperation(result) {
            val exercises = mutableListOf<String>()
            wrapper.api.listExercises(identifier).collect {
                exercises.add(gson.toJson(it))
            }
            exercises
        }
    }

    private fun fetchExercise(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val entry = gson.fromJson(arguments[1] as String, PolarExerciseEntry::class.java)

        launchOperation(result) {
            gson.toJson(wrapper.api.fetchExercise(identifier, entry))
        }
    }

    private fun removeExercise(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val entry = gson.fromJson(arguments[1] as String, PolarExerciseEntry::class.java)

        launchOperation(result) {
            wrapper.api.removeExercise(identifier, entry)
            null
        }
    }

    private fun setLedConfig(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val config = gson.fromJson(arguments[1] as String, LedConfig::class.java)

        launchOperation(result) {
            wrapper.api.setLedConfig(identifier, config)
            null
        }
    }

    private fun doFactoryReset(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val preservePairingInformation = arguments[1] as Boolean

        launchOperation(result) {
            @Suppress("DEPRECATION")
            wrapper.api.doFactoryReset(identifier, preservePairingInformation)
            null
        }
    }

    private fun doRestart(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            wrapper.api.doRestart(identifier)
            null
        }
    }

    private fun isFeatureReady(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val feature = PolarBleSdkFeature.valueOf(arguments[1] as String)
        result.success(wrapper.api.isFeatureReady(identifier, feature))
    }

    private fun enableSdkMode(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            wrapper.api.enableSDKMode(identifier)
            null
        }
    }

    private fun disableSdkMode(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            wrapper.api.disableSDKMode(identifier)
            null
        }
    }

    private fun isSdkModeEnabled(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String
        launchOperation(result) {
            wrapper.api.isSDKModeEnabled(identifier)
        }
    }

    private fun doFirstTimeUse(
        call: MethodCall,
        result: Result,
    ) {
        val arguments = call.arguments as List<*>
        val identifier = arguments[0] as String
        val ftuConfig = gson.fromJson(arguments[1] as String, PolarFirstTimeUseConfig::class.java)

        launchOperation(result) {
            wrapper.api.doFirstTimeUse(identifier, ftuConfig)
            null
        }
    }

    private fun isFtuDone(
        call: MethodCall,
        result: Result,
    ) {
        val identifier = call.arguments as String

        launchOperation(result) {
            wrapper.api.isFtuDone(identifier)
        }
    }
}

class PolarWrapper(
    context: Context,
    val api: PolarBleApi =
        PolarBleApiDefaultImpl.defaultImplementation(
            context,
            PolarBleSdkFeature.values().toSet(),
        ),
    private val sinks: MutableMap<Int, EventSink> = mutableMapOf(),
) : PolarBleApiCallbackProvider {
    private var isShutdown = false

    init {
        api.setApiCallback(this)
    }

    fun addSink(
        id: Int,
        sink: EventSink,
    ) {
        sinks[id] = sink
    }

    fun removeSink(id: Int) {
        sinks.remove(id)
    }

    private fun success(
        event: String,
        data: Any?,
    ) {
        runOnUiThread { sinks.values.forEach { it.success(mapOf("event" to event, "data" to data)) } }
    }

    fun shutDown(): Boolean {
        // Do not shutdown the api if other engines are still using it
        if (sinks.isNotEmpty()) return false
        if (!isShutdown) {
            api.shutDown()
            isShutdown = true
        }
        return true
    }

    override fun blePowerStateChanged(powered: Boolean) {
        success("blePowerStateChanged", powered)
    }

    override fun bleSdkFeatureReady(
        identifier: String,
        feature: PolarBleSdkFeature,
    ) {
        success("sdkFeatureReady", listOf(identifier, feature.name))
    }

    override fun bleSdkFeaturesReadiness(
        identifier: String,
        ready: List<PolarBleSdkFeature>,
        unavailable: List<PolarBleSdkFeature>,
    ) {
        // Individual ready features are exposed through bleSdkFeatureReady.
    }

    override fun deviceConnected(polarDeviceInfo: PolarDeviceInfo) {
        success("deviceConnected", gson.toJson(polarDeviceInfo))
    }

    override fun deviceConnecting(polarDeviceInfo: PolarDeviceInfo) {
        success("deviceConnecting", gson.toJson(polarDeviceInfo))
    }

    override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo) {
        success(
            "deviceDisconnected",
            // The second argument is the `pairingError` field on iOS
            // Since Android doesn't implement that, always send false
            listOf(gson.toJson(polarDeviceInfo), false),
        )
    }

    override fun disInformationReceived(
        identifier: String,
        uuid: UUID,
        value: String,
    ) {
        success("disInformationReceived", listOf(identifier, uuid.toString(), value))
    }

    override fun disInformationReceived(
        identifier: String,
        disInfo: DisInfo,
    ) {
        success("disInformationReceived", listOf(identifier, disInfo.key, disInfo.value))
    }

    override fun batteryLevelReceived(
        identifier: String,
        level: Int,
    ) {
        success("batteryLevelReceived", listOf(identifier, level))
    }

    override fun batteryChargingStatusReceived(
        identifier: String,
        chargingStatus: ChargeState,
    ) {
        success("batteryChargingStatusReceived", listOf(identifier, chargingStatus.name))
    }

    override fun htsNotificationReceived(
        identifier: String,
        data: PolarHealthThermometerData,
    ) {
        // Do nothing
    }

    override fun powerSourcesStateReceived(
        identifier: String,
        powerSourcesState: PowerSourcesState,
    ) {
        // The Dart API does not currently expose this callback.
    }

    @Deprecated("", replaceWith = ReplaceWith(""))
    override fun hrNotificationReceived(
        identifier: String,
        data: PolarHrData.PolarHrSample,
    ) {
        // Do nothing
    }
}

class StreamingChannel(
    messenger: BinaryMessenger,
    name: String,
    private val api: PolarBleApi,
    private val identifier: String,
    private val feature: PolarDeviceDataType,
    private val channel: EventChannel = EventChannel(messenger, name),
) : EventChannel.StreamHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var streamingJob: Job? = null

    init {
        channel.setStreamHandler(this)
    }

    override fun onListen(
        arguments: Any?,
        events: EventSink,
    ) {
        streamingJob?.cancel()

        // Will be null for some features
        val settings = gson.fromJson(arguments as String, PolarSensorSetting::class.java)

        val stream: Flow<*> =
            when (feature) {
                PolarDeviceDataType.HR -> {
                    api.startHrStreaming(identifier)
                }

                PolarDeviceDataType.ECG -> {
                    api.startEcgStreaming(identifier, settings)
                }

                PolarDeviceDataType.ACC -> {
                    api.startAccStreaming(identifier, settings)
                }

                PolarDeviceDataType.PPG -> {
                    api.startPpgStreaming(identifier, settings)
                }

                PolarDeviceDataType.PPI -> {
                    api.startPpiStreaming(identifier)
                }

                PolarDeviceDataType.GYRO -> {
                    api.startGyroStreaming(identifier, settings)
                }

                PolarDeviceDataType.MAGNETOMETER -> {
                    api.startMagnetometerStreaming(
                        identifier,
                        settings,
                    )
                }

                PolarDeviceDataType.TEMPERATURE -> {
                    api.startTemperatureStreaming(
                        identifier,
                        settings,
                    )
                }

                PolarDeviceDataType.PRESSURE -> {
                    api.startPressureStreaming(identifier, settings)
                }

                PolarDeviceDataType.SKIN_TEMPERATURE -> {
                    api.startSkinTemperatureStreaming(identifier, settings)
                }

                PolarDeviceDataType.LOCATION -> {
                    api.startLocationStreaming(identifier, settings)
                }

                PolarDeviceDataType.DERIVED_MEASUREMENT -> {
                    events.error(
                        "Unsupported Polar data type",
                        "DERIVED_MEASUREMENT is not exposed by the Dart API",
                        null,
                    )
                    return
                }
            }

        streamingJob =
            scope.launch {
                try {
                    stream.collect {
                        runOnUiThread {
                            if (streamingJob?.isActive == true) {
                                events.success(gson.toJson(it))
                            }
                        }
                    }
                    runOnUiThread {
                        if (streamingJob?.isActive == true) {
                            events.endOfStream()
                        }
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    runOnUiThread {
                        if (streamingJob?.isActive == true) {
                            events.error(error.toString(), error.message, null)
                        }
                    }
                }
            }
    }

    override fun onCancel(arguments: Any?) {
        streamingJob?.cancel()
        streamingJob = null
    }

    fun dispose() {
        streamingJob?.cancel()
        streamingJob = null
        scope.cancel()
        channel.setStreamHandler(null)
    }
}
