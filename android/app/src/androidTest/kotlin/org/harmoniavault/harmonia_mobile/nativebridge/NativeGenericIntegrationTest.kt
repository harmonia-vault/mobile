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
class NativeGenericIntegrationTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private val alias="harmonia/synthetic-generic-test/v1"
    private val keyFilename="synthetic-generic-key.gcm"
    private val stateFilename="synthetic-generic-state.gcm"
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
        Log.i("HarmoniaNativeTest","AWAIT_GENERIC_AUTH:$phase")
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
    private fun approvals()=JSONObject(https("/test/counters")).getLong("approvals")
    private fun cleanup() {
        val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};if(keys.containsAlias(alias))keys.deleteEntry(alias)
        for(name in listOf(keyFilename,stateFilename)){val file=File(File(context.noBackupFilesDir,"harmonia"),name);file.delete();File(file.path+".bak").delete();File(file.path+".new").delete()}
    }
    @Test fun testCert3NonRootYOnlyEnrollmentRotationAndDefaultCLI() {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename);assertTrue(store.supported())
        lateinit var plugin:NativeBridgePlugin
        fun connect(){instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca){check(saves.incrementAndGet()!=failAt)}}}
        fun execute(op:String,fields:Map<String,String> = emptyMap())=request(plugin,"executeWorkflow",command(op,fields),op)
        connect()
        try {
            val device=request(plugin,"createDevice",null,"createDevice").getString("deviceId")
            val socketName=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            var email="";var x="";var y=""
            NativeGenericTestSocket(socketName){JSONObject().put("email",email).put("approver",device).put("environment",y).put("deniedEnvironment",x).put("expiry",System.currentTimeMillis()/1000+3600)}.use {socket ->
                Log.i("HarmoniaNativeTest","AWAIT_GENERIC_ROOT_SOCKET:root-a")
                socket.nextEnrollment().use {packet ->
                    email=packet.metadata.getString("email");x=packet.metadata.getString("x");y=packet.metadata.getString("y")
                    assertNotEquals(device,packet.metadata.getString("approver"))
                    val id=packet.metadata.getString("pairingId")
                    // Receipt/root/checkpoint保存后，最终Applied保存失败仍不输出任何业务值。
                    saves.set(0);failAt=4
                    val incoming=packet.code.copyOf()
                    val enrolled=request(plugin,"executeEnrollment",mapOf("command" to command("enrollDeviceV3",mapOf("email" to email,"password" to "synthetic-cross-password-only","pairingId" to id,"approverDeviceId" to packet.metadata.getString("approver"))),"shortCode" to incoming),"enroll-device-v3")
                    assertTrue(incoming.all{it==0.toByte()});packet.code.fill(0);failAt=0
                    assertFalse(enrolled.getBoolean("ok"));assertEquals("PENDING",enrolled.getString("code"));assertFalse(enrolled.has("data"));assertEquals(4,saves.get())
                    packet.candidateCompleted()
                    val info=execute("enrollmentInfoV3").getJSONObject("data")
                    assertEquals("accepted-not-applied",info.getString("state"));assertFalse(info.getBoolean("trustedDevice"));assertEquals(id,info.getString("pairingId"))
                    val hidden=execute("view");assertFalse(hidden.getBoolean("ok"));assertEquals("PENDING",hidden.getString("code"));assertFalse(hidden.has("data"))
                    instrumentation.runOnMainSync{plugin.dispose()};connect()
                    val resumed=execute("resumeEnrollmentV3",mapOf("pairingId" to id));assertTrue(resumed.getBoolean("ok"))
                    val view=resumed.getJSONObject("data");assertEquals(device,view.getString("deviceId"));assertEquals(1,view.getJSONArray("environments").length())
                    val env=view.getJSONArray("environments").getJSONObject(0);assertEquals(y,env.getString("id"));assertEquals("Admin",env.getString("role"));assertFalse(env.getJSONObject("variables").has("SYNTHETIC_X_ONLY"))
                    val ready=execute("enrollmentInfoV3").getJSONObject("data");assertEquals("complete",ready.getString("state"));assertTrue(ready.getBoolean("trustedDevice"))
                }
                val before=JSONObject(https("/test/counters")).getLong("approvalsV3")
                assertEquals(1,before);assertEquals(0,approvals())
                val denied=execute("setVariable",mapOf("environmentId" to x,"name" to "SYNTHETIC_FORBIDDEN","value" to "synthetic-denied","id" to "native-generic-denied-write"));assertFalse(denied.getBoolean("ok"));assertFalse(denied.has("data"));assertEquals("UNAUTHORIZED",denied.getString("code"))
                assertFalse(execute("rotateEnvironmentKey",mapOf("environmentId" to x,"id" to "native-generic-denied-rotate")).getBoolean("ok"))
                val deniedChoice=JSONArray().put(JSONObject().put("environmentId",x).put("role","rw").put("expiresAt","0"))
                val denyCode=byteArrayOf(48,48,48,48,48,48,48,48)
                val denyApproval=request(plugin,"executeApproval",mapOf("command" to command("approvePairingV3",mapOf("pairingId" to "native-generic-denied-approval","selections" to deniedChoice.toString())),"shortCode" to denyCode),"deny-x-approval")
                assertFalse(denyApproval.getBoolean("ok"));assertEquals("UNAUTHORIZED",denyApproval.getString("code"));assertTrue(denyCode.all{it==0.toByte()});assertEquals(before,JSONObject(https("/test/counters")).getLong("approvalsV3"))
                val rotated=execute("rotateEnvironmentKey",mapOf("environmentId" to y,"id" to "native-generic-rotate-y"));assertTrue(rotated.getBoolean("ok"))
                val same=execute("rotateEnvironmentKey",mapOf("environmentId" to y,"id" to "native-generic-rotate-y"));assertTrue(same.getBoolean("ok"));assertEquals(rotated.getJSONObject("data").getLong("checkpoint"),same.getJSONObject("data").getLong("checkpoint"))
                assertTrue(execute("setVariable",mapOf("environmentId" to y,"name" to "SYNTHETIC_CROSS","value" to "synthetic-cross-value","id" to "native-generic-y-value")).getBoolean("ok"))
                Log.i("HarmoniaNativeTest","AWAIT_LOCAL_PAIRING_SOCKET:generic-default-3")
                socket.nextPacket().use {packet ->
                    assertEquals(y,packet.environment)
                    val choices=JSONArray().put(JSONObject().put("environmentId",y).put("role","rw").put("expiresAt",packet.expiry.toString()))
                    https("/test/control",JSONObject().put("lose","approvalV3"))
                    val incoming=packet.shortCode.copyOf()
                    val out=request(plugin,"executeApproval",mapOf("command" to command("approvePairingV3",mapOf("pairingId" to packet.pairingId,"selections" to choices.toString())),"shortCode" to incoming),"approve-v3-lost-response")
                    packet.shortCode.fill(0);assertTrue(incoming.all{it==0.toByte()})
                    assertFalse(out.getBoolean("ok"));assertEquals("PENDING",out.getString("code"));assertEquals("unknown",out.getJSONObject("data").getString("state"));assertEquals(before+1,JSONObject(https("/test/counters")).getLong("approvalsV3"));assertEquals(0,approvals())
                    val info=execute("approvalInfoV3").getJSONObject("data");assertEquals(packet.pairingId,info.getString("pairingId"));assertEquals(y,info.getJSONArray("selections").getJSONObject(0).getString("environmentId"));assertEquals("rw",info.getJSONArray("selections").getJSONObject(0).getString("role"));assertEquals(packet.expiry.toString(),info.getJSONArray("selections").getJSONObject(0).getString("expiresAt"))
                    val hidden=execute("view");assertFalse(hidden.getBoolean("ok"));assertFalse(hidden.has("data"));assertEquals("PENDING",hidden.getString("code"))
                    assertFalse(execute("cancelApprovalV3",mapOf("pairingId" to packet.pairingId)).getBoolean("ok"))
                    packet.acknowledge("UNKNOWN");socket.awaitCompiledCLIStage()
                    instrumentation.runOnMainSync{plugin.dispose()};connect()
                    val done=execute("retryApprovalV3",mapOf("pairingId" to packet.pairingId));assertTrue(done.getBoolean("ok"));assertEquals("complete",done.getJSONObject("data").getString("state"));assertTrue(done.getJSONObject("data").getLong("sequence")>0);assertEquals(before+1,JSONObject(https("/test/counters")).getLong("approvalsV3"))
                    val pulled=execute("pull");assertTrue(pulled.getBoolean("ok"));val envs=pulled.getJSONObject("data").getJSONArray("environments");assertEquals(1,envs.length());assertEquals(y,envs.getJSONObject(0).getString("id"));assertEquals("synthetic-cli-write",envs.getJSONObject(0).getJSONObject("variables").getString("SYNTHETIC_CLI"))
                }
            }
            assertTrue(execute("logout").getBoolean("ok"));assertFalse(store.exists());assertFalse(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
        } finally {failAt=0;instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
}
