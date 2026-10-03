package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Intent
import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.harmoniavault.harmonia_mobile.MainActivity
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import java.net.URL

/** 仅真实恢复/系统认证/跨进程原签状态，不编写或测试Flutter UI。 */
class NativeRecoveryIntegrationTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private val alias="harmonia/synthetic-recovery-test/v1"
    private val keyFilename="synthetic-recovery-key.gcm"
    private val stateFilename="synthetic-recovery-state.gcm"
    private val endpoint="https://10.0.2.2:4443"
    private val ca=Base64.decode(InstrumentationRegistry.getArguments().getString("syntheticCA")!!,Base64.NO_WRAP)
    private val saves=AtomicInteger(0)
    @Volatile private var failAt=0
    @Volatile private var failFinalSeal=false
    private val finalSealHits=AtomicInteger(0)
    private val messenger=object:BinaryMessenger {
        override fun send(channel:String,message:ByteBuffer?){}
        override fun send(channel:String,message:ByteBuffer?,callback:BinaryMessenger.BinaryReply?){}
        override fun setMessageHandler(channel:String,handler:BinaryMessenger.BinaryMessageHandler?){}
    }
    private class Outcome:MethodChannel.Result {
        val ready=CountDownLatch(1);var value:Any?=null;var code:String?=null
        override fun success(result:Any?){value=result;ready.countDown()}
        override fun error(errorCode:String,errorMessage:String?,errorDetails:Any?){code=errorCode;ready.countDown()}
        override fun notImplemented(){code="NOT_IMPLEMENTED";ready.countDown()}
    }
    private fun request(plugin:NativeBridgePlugin,method:String,args:Any?,phase:String):JSONObject {
        val out=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall(method,args),out)}
        Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_AUTH:$phase")
        assertTrue("native approval timed out",out.ready.await(135,TimeUnit.SECONDS))
        assertNull("native approval bridge rejected: ${out.code}",out.code)
        return JSONObject(out.value as String)
    }
    /** 同步native存储回调拒绝可经JNI保留为固定platform error；两种错误都不得授予数据。 */
    private fun rejectedProtectedSave(plugin:NativeBridgePlugin,op:String,fields:Map<String,String>):JSONObject? {
        val out=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command(op,fields)),out)}
        Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_AUTH:$op")
        assertTrue("native save rejection timed out",out.ready.await(135,TimeUnit.SECONDS))
        if(out.code!=null){
            assertEquals("GO_OR_KEYSTORE_REJECTED",out.code);assertNull(out.value)
            Log.i("HarmoniaNativeTest","EXPECTED_RECOVERY_SAVE_BOUNDARY:platform-rejected")
            return null
        }
        val result=JSONObject(out.value as String);assertFalse(result.getBoolean("ok"))
        Log.i("HarmoniaNativeTest","EXPECTED_RECOVERY_SAVE_BOUNDARY:business-rejected")
        return result
    }
    private fun cancelRecoveryAuthentication(plugin:NativeBridgePlugin) {
        val out=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command("recoveryView")),out)}
        Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_AUTH:cancel-recovery-owner")
        assertTrue("native cancellation timed out",out.ready.await(135,TimeUnit.SECONDS))
        assertEquals("AUTH_CANCELLED",out.code)
    }
    private fun command(op:String,fields:Map<String,String> = emptyMap()):String {
        val json=JSONObject().put("version",1).put("operation",op).put("endpoint",endpoint)
        for((k,v)in fields)json.put(k,v);return json.toString()
    }
    private fun https(path:String,body:JSONObject?=null):String {
        val cert=CertificateFactory.getInstance("X.509").generateCertificate(ca.inputStream())
        val trust=KeyStore.getInstance(KeyStore.getDefaultType()).apply{load(null);setCertificateEntry("synthetic-ca",cert)}
        val tm=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply{init(trust)}
        val tls=SSLContext.getInstance("TLS").apply{init(null,tm.trustManagers,null)}
        val conn=URL(endpoint+path).openConnection() as HttpsURLConnection
        conn.sslSocketFactory=tls.socketFactory;conn.connectTimeout=5000;conn.readTimeout=5000
        if(body!=null){conn.requestMethod="POST";conn.doOutput=true;conn.setRequestProperty("Content-Type","application/json");conn.outputStream.use{it.write(body.toString().toByteArray())}}
        try{assertEquals(200,conn.responseCode);return conn.inputStream.bufferedReader().use{it.readText()}}finally{conn.disconnect()}
    }
    private fun counter(name:String)=JSONObject(https("/test/counters")).getLong(name)
    private fun cleanup() {
        val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};if(keys.containsAlias(alias))keys.deleteEntry(alias)
        for(name in listOf(keyFilename,stateFilename)){val file=File(File(context.noBackupFilesDir,"harmonia"),name);file.delete();File(file.path+".bak").delete();File(file.path+".new").delete()}
    }
    private fun start():Triple<MainActivity,ProtectedDeviceStore,NativeBridgePlugin> {
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val store=ProtectedDeviceStore(context,alias,keyFilename);assertTrue(store.supported())
        lateinit var plugin:NativeBridgePlugin
        instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca,
            beforeWorkflowPacketSave={packet ->
                if(failFinalSeal){
                    // 只选故障阶段，不据header授予权限。Go最后applied保存才产生普通cloud checkpoint>0。
                    check(packet.size>=40)
                    val n=ByteBuffer.wrap(packet,8,4).int;check(n in 1..4096 && 12+n+28<=packet.size)
                    val header=JSONObject(String(packet,12,n,Charsets.UTF_8))
                    if(header.getLong("checkpoint")>0){finalSealHits.incrementAndGet();error("synthetic final native seal rejected")}
                }
            }){check(saves.incrementAndGet()!=failAt)}}
        return Triple(activity,store,plugin)
    }
    private fun execute(plugin:NativeBridgePlugin,op:String,fields:Map<String,String> = emptyMap())=request(plugin,"executeWorkflow",command(op,fields),op)
    private fun requireRestricted(info:JSONObject){assertFalse(info.getBoolean("trustedDevice"))}
    private fun checkRecoveredValues(view:JSONObject,meta:JSONObject){
        requireRestricted(view.getJSONObject("info"));val envs=view.getJSONArray("environments");assertEquals(2,envs.length())
        for(i in 0 until envs.length()){
            val env=envs.getJSONObject(i);val id=env.getString("id")
            if(id==meta.getString("x")){assertEquals("2",env.getString("keyVersion"));assertEquals("synthetic-x-denied",env.getJSONObject("variables").getString("SYNTHETIC_X_ONLY"))}
            else{assertEquals(meta.getString("y"),id);assertEquals("synthetic-cross-value",env.getJSONObject("variables").getString("SYNTHETIC_CROSS"))}
        }
    }
    @Test fun test01OldCodeOwnerPrePostSealFailureAndUnknownTransition() {
        cleanup();val(activity,store,plugin)=start()
        try{
            request(plugin,"createDevice",null,"createDevice")
            val name=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            NativeRecoveryTestSocket(name).use{socket ->
                Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_ROOT_SOCKET:phase1")
                socket.packet(1).use{packet ->
                    val meta=packet.metadata;var oldCode=packet.code.toString(Charsets.UTF_8);packet.code.fill(0)
                    val begun=execute(plugin,"beginRecoveryAuthority",mapOf("email" to meta.getString("email"),"password" to "synthetic-cross-password-only","recoveryCode" to oldCode));assertTrue(begun.getBoolean("ok"));requireRestricted(begun.getJSONObject("data"))
                    checkRecoveredValues(execute(plugin,"recoveryView").getJSONObject("data"),meta)
                    cancelRecoveryAuthentication(plugin)
                    val canceled=execute(plugin,"recoveryView");assertFalse(canceled.getBoolean("ok"));assertFalse(canceled.has("data"));assertEquals("RECOVERY_RESTART_REQUIRED",canceled.getString("code"))
                    assertTrue(execute(plugin,"resumeRecoveryAuthority",mapOf("recoveryCode" to oldCode)).getBoolean("ok"))
                    val proposal=execute(plugin,"beginRecoveryTransition",mapOf("id" to "native-recovery-transition"));assertTrue(proposal.getBoolean("ok"));var newCode=proposal.getString("recoveryCode")
                    // 原两签包未保存成功不得POST，RAM oldOwner同步退役；显式中断恢复仍原id/nonce。
                    saves.set(0);failAt=1
                    rejectedProtectedSave(plugin,"completeRecoveryTransition",mapOf("recoveryCode" to newCode));failAt=0
                    assertEquals(1,saves.get());assertEquals(0,counter("recoveryTransitions"))
                    val hidden=execute(plugin,"recoveryView");assertFalse(hidden.getBoolean("ok"));assertFalse(hidden.has("data"));assertEquals("RECOVERY_RESTART_REQUIRED",hidden.getString("code"))
                    assertTrue(execute(plugin,"resumeRecoveryAuthority",mapOf("recoveryCode" to oldCode)).getBoolean("ok"));oldCode=""
                    https("/test/control",JSONObject().put("lose","recoveryTransition"))
                    val unknown=execute(plugin,"completeRecoveryTransition",mapOf("recoveryCode" to newCode));assertFalse(unknown.getBoolean("ok"));assertEquals("PENDING",unknown.getString("code"));requireRestricted(unknown.getJSONObject("data"));assertEquals(1,counter("recoveryTransitions"))
                    val info=execute(plugin,"recoveryInfo").getJSONObject("data");requireRestricted(info);assertEquals("native-recovery-transition",info.getString("id"))
                    val queried=execute(plugin,"queryRecoveryTransition");assertTrue(queried.getBoolean("ok"));requireRestricted(queried.getJSONObject("data"));assertEquals("native-recovery-transition",queried.getJSONObject("data").getString("id"))
                    val bytes=newCode.toByteArray(Charsets.UTF_8)
                    try{packet.retainDisplayedNewCode(bytes)}finally{bytes.fill(0);newCode=""}
                }
            }
            assertTrue(store.exists());assertTrue(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
        }finally{failAt=0;failFinalSeal=false;instrumentation.runOnMainSync{plugin.dispose();activity.finish()}}
    }
    @Test fun test02NewCodeAfterRealProcessStopAndCert4FinalSealFailure(){
        val(activity,store,plugin)=start();assertTrue(store.exists())
        try{
            val name=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            NativeRecoveryTestSocket(name).use{socket ->
                Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_PHASE_SOCKET:phase2")
                socket.packet(2).use{packet ->
                    var code=packet.code.toString(Charsets.UTF_8);packet.code.fill(0)
                    val restored=execute(plugin,"completeRecoveryTransition",mapOf("recoveryCode" to code));code=""
                    assertTrue(restored.getBoolean("ok"));requireRestricted(restored.getJSONObject("data"));assertFalse(restored.getJSONObject("data").getBoolean("rotationRequired"));assertEquals(1,counter("recoveryTransitions"))
                    checkRecoveredValues(execute(plugin,"recoveryView").getJSONObject("data"),packet.metadata)
                    val ordinary=execute(plugin,"view");assertFalse(ordinary.getBoolean("ok"));assertFalse(ordinary.has("data"));assertEquals("RECOVERY_RESTRICTED",ordinary.getString("code"))
                    val selections=JSONArray().put(JSONObject().put("environmentId",packet.metadata.getString("x")).put("role","ro").put("expiresAt",(System.currentTimeMillis()/1000+3600).toString())).put(JSONObject().put("environmentId",packet.metadata.getString("y")).put("role","admin").put("expiresAt","0"))
                    saves.set(0);finalSealHits.set(0);failFinalSeal=true
                    val pending=rejectedProtectedSave(plugin,"registerRecoveredDevice",mapOf("id" to "native-recovery-enroll-e","selections" to selections.toString()));failFinalSeal=false
                    Log.i("HarmoniaNativeTest","RECOVERY_REGISTRATION_DIAGNOSTIC:saves=${saves.get()},challengeStatus=${counter("recoveredChallengeStatus")},deviceAttempts=${counter("recoveredDeviceAttempts")},deviceStatus=${counter("recoveredDeviceStatus")}")
                    if(pending!=null){assertEquals("PENDING",pending.getString("code"));requireRestricted(pending.getJSONObject("data"))};assertEquals(1,finalSealHits.get());assertEquals(1,counter("recoveredDevices"));assertEquals(1,counter("recoveredDeviceAttempts"));assertEquals(200,counter("recoveredDeviceStatus"))
                    val info=execute(plugin,"recoveredDeviceInfo").getJSONObject("data");requireRestricted(info);assertEquals("accepted-not-applied",info.getString("state"));assertEquals("native-recovery-enroll-e",info.getString("id"))
                    val hidden=execute(plugin,"view");assertFalse(hidden.getBoolean("ok"));assertFalse(hidden.has("data"))
                    packet.acknowledge("REGISTRATION_PENDING")
                }
            }
        }finally{failAt=0;failFinalSeal=false;instrumentation.runOnMainSync{plugin.dispose();activity.finish()}}
    }
    @Test fun test03OriginalCert4RetryTrustedEAndExplicitCLI4(){
        val(activity,store,plugin)=start();assertTrue(store.exists())
        try{
            val name=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            var email="";var x="";var y=""
            NativeRecoveryTestSocket(name).use{socket ->
                Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_PHASE_SOCKET:phase3")
                socket.packet(3).use{packet ->
                    assertEquals(0,packet.code.size);email=packet.metadata.getString("email");x=packet.metadata.getString("x");y=packet.metadata.getString("y")
                    val ready=execute(plugin,"retryRecoveredDevice",mapOf("id" to "native-recovery-enroll-e"));assertTrue(ready.getBoolean("ok"));assertTrue(ready.getJSONObject("data").getBoolean("trustedDevice"));assertEquals(1,counter("recoveredDevices"))
                    val rows=execute(plugin,"view").getJSONObject("data").getJSONArray("environments");assertEquals(2,rows.length())
                    for(i in 0 until rows.length()){val r=rows.getJSONObject(i);assertEquals(if(r.getString("id")==x)"RO" else "Admin",r.getString("role"))}
                    val denied=execute(plugin,"setVariable",mapOf("environmentId" to x,"name" to "SYNTHETIC_FORBIDDEN","value" to "synthetic-denied","id" to "native-recovery-ro-denied"));assertFalse(denied.getBoolean("ok"));assertFalse(denied.has("data"));assertEquals("UNAUTHORIZED",denied.getString("code"))
                    assertTrue(execute(plugin,"setVariable",mapOf("environmentId" to y,"name" to "SYNTHETIC_CROSS","value" to "synthetic-cross-value","id" to "native-recovery-e-write")).getBoolean("ok"))
                    packet.acknowledge("RECOVERED_TRUSTED")
                }
            }
            val device=execute(plugin,"view").getJSONObject("data").getString("deviceId")
            NativePairingTestSocket(name){JSONObject().put("email",email).put("approver",device).put("environment",y).put("deniedEnvironment",x).put("expiry",System.currentTimeMillis()/1000+3600)}.use{socket ->
                Log.i("HarmoniaNativeTest","AWAIT_RECOVERY_CLI_SOCKET:explicit-4")
                socket.nextPacket().use{packet ->
                    val selections=JSONArray().put(JSONObject().put("environmentId",y).put("role","rw").put("expiresAt",packet.expiry.toString()))
                    val bytes=packet.shortCode.copyOf()
                    val approved=request(plugin,"executeApproval",mapOf("command" to command("approvePairingV4",mapOf("pairingId" to packet.pairingId,"selections" to selections.toString())),"shortCode" to bytes),"approve-cli4")
                    packet.shortCode.fill(0);assertTrue(bytes.all{it==0.toByte()});assertTrue(approved.getBoolean("ok"));assertEquals(1,counter("approvalsV4"));assertEquals(0,counter("approvalsV3"));assertEquals(0,counter("approvals"))
                    val manager=execute(plugin,"approvalInfoV4");assertTrue(manager.getBoolean("ok"));assertEquals("approved",manager.getJSONObject("data").getString("state"))
                    val cancel=execute(plugin,"cancelApprovalV4",mapOf("pairingId" to packet.pairingId));assertFalse(cancel.getBoolean("ok"));assertEquals(1,counter("approvalsV4"))
                    packet.acknowledge("APPROVED");socket.awaitCompiledCLIStage()
                    val complete=execute(plugin,"retryApprovalV4",mapOf("pairingId" to packet.pairingId));assertTrue(complete.getBoolean("ok"));assertEquals("complete",complete.getJSONObject("data").getString("state"));assertEquals(1,counter("approvalsV4"))
                    assertEquals("synthetic-cli-write",execute(plugin,"pull").getJSONObject("data").getJSONArray("environments").let{rows -> (0 until rows.length()).map{rows.getJSONObject(it)}.first{it.getString("id")==y}}.getJSONObject("variables").getString("SYNTHETIC_CLI"))
                }
            }
            assertTrue(execute(plugin,"logout").getBoolean("ok"));assertFalse(store.exists());assertFalse(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
        }finally{failAt=0;failFinalSeal=false;instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
}
