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

/** 只验原生业务、强认证与真实compiled CLI，不编写或测试Flutter UI。 */
class NativePairingIntegrationTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private val alias="harmonia/synthetic-pairing-test/v1"
    private val keyFilename="synthetic-pairing-key.gcm"
    private val stateFilename="synthetic-pairing-state.gcm"
    private val endpoint="https://10.0.2.2:4443"
    private val ca=Base64.decode(InstrumentationRegistry.getArguments().getString("syntheticCA")!!,Base64.NO_WRAP)
    private val saves=AtomicInteger(0)
    @Volatile private var failAt=0
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
        Log.i("HarmoniaNativeTest","AWAIT_PAIRING_AUTH:$phase")
        assertTrue("native approval timed out",out.ready.await(135,TimeUnit.SECONDS))
        assertNull("native approval bridge rejected: ${out.code}",out.code)
        return JSONObject(out.value as String)
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
    private fun approvals()=JSONObject(https("/test/counters")).getLong("approvalsV5")
    private fun cleanup() {
        val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};if(keys.containsAlias(alias))keys.deleteEntry(alias)
        for(name in listOf(keyFilename,stateFilename)){val file=File(File(context.noBackupFilesDir,"harmonia"),name);file.delete();File(file.path+".bak").delete();File(file.path+".new").delete()}
    }
    @Test fun testStrongNativeManagerCompiledCLIAndUnknownSameID() {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename);assertTrue(store.supported())
        lateinit var plugin:NativeBridgePlugin
        fun connect(){instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca,beforeWorkflowSave={check(saves.incrementAndGet()!=failAt)})}}
        fun execute(op:String,fields:Map<String,String> = emptyMap())=request(plugin,"executeWorkflow",command(op,fields),op)
        connect()
        try {
            val device=request(plugin,"createDevice",null,"createDevice").getString("deviceId")
            val email="native-pair-${System.currentTimeMillis()}@example.invalid";val password="synthetic-cross-password-only"
            val registered=execute("register",mapOf("email" to email,"password" to password));assertTrue(registered.getBoolean("ok"));val registration=registered.getJSONObject("data")
            val mails=JSONArray(https("/test/emails"));var proof:JSONObject?=null
            for(i in 0 until mails.length()){val mail=mails.getJSONObject(i);if(mail.getString("to")==email)for(line in mail.getString("text").split('\n'))if(Regex("^[2-9A-HJ-NP-Z]{8}$").matches(line))proof=JSONObject().put("accountId",registration.getString("accountId")).put("accountGeneration",registration.getString("accountGeneration")).put("code",line)}
            assertNotNull(proof);assertTrue(execute("verifyEmail",listOf("accountId","accountGeneration","code").associateWith{proof!!.getString(it)}).getBoolean("ok"))
            val began=execute("beginInitialization",mapOf("email" to email,"password" to password,"name" to "跨端初始合成环境","id" to "native-pair-root"));assertTrue(began.getBoolean("ok"))
            val view=execute("completeInitialization",mapOf("recoveryCode" to began.getString("recoveryCode"))).getJSONObject("data")
            val env=view.getJSONArray("environments").getJSONObject(0).getString("id")
            assertTrue(execute("setVariable",mapOf("environmentId" to env,"name" to "SYNTHETIC_CROSS","value" to "synthetic-cross-value","id" to "native-cross-put")).getBoolean("ok"))
            val stateFile=File(File(context.noBackupFilesDir,"harmonia"),stateFilename)
            // 取消发生在系统认证阶段；不能开始PAKE或改变AES文件。
            val original=stateFile.readBytes();val beforeCancel=approvals()
            val cancelled=Outcome();val cancellationCode=byteArrayOf(48,48,48,48,48,48,48,48)
            val cancellationCommand=command("approvePairingV5",mapOf("pairingId" to "synthetic-cancel-before-pake","selections" to JSONArray().put(JSONObject().put("environmentId",env).put("role","rw").put("expiresAt",(System.currentTimeMillis()/1000+3600).toString())).toString()))
            instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeApproval",mapOf("command" to cancellationCommand,"shortCode" to cancellationCode)),cancelled)}
            assertTrue(cancellationCode.all{it==0.toByte()})
            val busy=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command("view")),busy)}
            assertTrue(busy.ready.await(10,TimeUnit.SECONDS));assertEquals("BUSY",busy.code)
            Log.i("HarmoniaNativeTest","AWAIT_PAIRING_AUTH:cancel-approval")
            assertTrue(cancelled.ready.await(60,TimeUnit.SECONDS));assertEquals("AUTH_CANCELLED",cancelled.code)
            assertTrue(original.contentEquals(stateFile.readBytes()));assertEquals(beforeCancel,approvals())
            val socketName=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            NativePairingTestSocket(socketName){JSONObject().put("email",email).put("approver",device).put("environment",env).put("expiry",System.currentTimeMillis()/1000+3600)}.use {socket ->
                var accepted=approvals();var completedID=""
                for(stage in listOf("known","lost-response","prepared-save-failure","attempted-save-failure")) {
                    Log.i("HarmoniaNativeTest","AWAIT_LOCAL_PAIRING_SOCKET:$stage")
                    socket.nextPacket().use {packet ->
                        assertEquals(env,packet.environment)
                        val choices=JSONArray().put(JSONObject().put("environmentId",env).put("role","rw").put("expiresAt",packet.expiry.toString()))
                        if(stage=="lost-response")https("/test/control",JSONObject().put("lose","approvalV5"))
                        saves.set(0);failAt=when(stage){"prepared-save-failure"->3;"attempted-save-failure"->5;else->0}
                        val incoming=packet.shortCode.copyOf()
                        val out=request(plugin,"executeApproval",mapOf("command" to command("approvePairingV5",mapOf("pairingId" to packet.pairingId,"selections" to choices.toString())),"shortCode" to incoming),stage)
                        packet.shortCode.fill(0);assertTrue(incoming.all{it==0.toByte()});failAt=0
                        when(stage) {
                            "known" -> {assertTrue(out.getBoolean("ok"));assertTrue(out.getJSONObject("data").getString("state") in listOf("approved","complete"));accepted++;assertEquals(accepted,approvals());packet.acknowledge("APPROVED")}
                            "lost-response" -> {
                                assertFalse(out.getBoolean("ok"));assertEquals("PENDING",out.getString("code"));assertEquals("unknown",out.getJSONObject("data").getString("state"));accepted++;assertEquals(accepted,approvals())
                                val info=execute("approvalInfoV5").getJSONObject("data");assertEquals(packet.pairingId,info.getString("pairingId"));assertEquals("rw",info.getJSONArray("selections").getJSONObject(0).getString("role"));assertEquals(packet.expiry.toString(),info.getJSONArray("selections").getJSONObject(0).getString("expiresAt"))
                                val hidden=execute("view");assertFalse(hidden.getBoolean("ok"));assertFalse(hidden.has("data"));assertEquals("PENDING",hidden.getString("code"))
                                assertFalse(execute("cancelApprovalV5",mapOf("pairingId" to packet.pairingId)).getBoolean("ok"));packet.acknowledge("UNKNOWN")
                            }
                            "prepared-save-failure" -> {
                                assertFalse(out.getBoolean("ok"));assertEquals(3,saves.get());assertEquals(accepted,approvals())
                                val info=execute("approvalInfoV5").getJSONObject("data");assertEquals("complete",info.getString("state"));assertEquals(completedID,info.getString("pairingId"));packet.acknowledge("REJECTED")
                            }
                            "attempted-save-failure" -> {
                                assertFalse(out.getBoolean("ok"));assertEquals(5,saves.get());assertEquals(accepted,approvals())
                                val info=execute("approvalInfoV5").getJSONObject("data");assertEquals("prepared",info.getString("state"));assertEquals(packet.pairingId,info.getString("pairingId"))
                                assertTrue(execute("cancelApprovalV5",mapOf("pairingId" to packet.pairingId)).getBoolean("ok"));assertEquals("none",execute("approvalInfoV5").getJSONObject("data").getString("state"));packet.acknowledge("REJECTED")
                            }
                        }
                        socket.awaitCompiledCLIStage()
                        if(stage=="known" || stage=="lost-response") {
                            instrumentation.runOnMainSync{plugin.dispose()};connect()
                            val done=execute("retryApprovalV5",mapOf("pairingId" to packet.pairingId));assertTrue(done.getBoolean("ok"));assertEquals("complete",done.getJSONObject("data").getString("state"));assertTrue(done.getJSONObject("data").getLong("sequence")>0)
                            assertEquals(accepted,approvals());completedID=packet.pairingId
                        }
                    }
                }
            }
            assertTrue(execute("logout").getBoolean("ok"));assertFalse(store.exists());assertFalse(stateFile.exists())
        } finally {failAt=0;instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
}
