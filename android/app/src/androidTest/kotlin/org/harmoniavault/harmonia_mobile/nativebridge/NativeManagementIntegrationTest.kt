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

/** 只验原生管理/强认证/真实Go对端；不声明对端桌面系统认证，不测试Flutter UI。 */
class NativeManagementIntegrationTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private val alias="harmonia/synthetic-management-test/v1"
    private val keyFilename="synthetic-management-key.gcm"
    private val stateFilename="synthetic-management-state.gcm"
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
        Log.i("HarmoniaNativeTest","AWAIT_MANAGEMENT_AUTH:$phase")
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
    private fun counter(name:String)=JSONObject(https("/test/counters")).getLong(name)
    private fun cleanup() {
        val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};if(keys.containsAlias(alias))keys.deleteEntry(alias)
        for(name in listOf(keyFilename,stateFilename)){val file=File(File(context.noBackupFilesDir,"harmonia"),name);file.delete();File(file.path+".bak").delete();File(file.path+".new").delete()}
    }
    @Test fun testImmutableManagementJournalPermissionsRotationAndRevocation() {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename);assertTrue(store.supported())
        lateinit var plugin:NativeBridgePlugin
        fun connect(){instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca,beforeWorkflowSave={check(saves.incrementAndGet()!=failAt)})}}
        fun execute(op:String,fields:Map<String,String> = emptyMap())=request(plugin,"executeWorkflow",command(op,fields),op)
        fun hidden(){val out=execute("view");assertFalse(out.getBoolean("ok"));assertFalse(out.has("data"));assertEquals("PENDING",out.getString("code"))}
        connect()
        try {
            val device=request(plugin,"createDevice",null,"createDevice").getString("deviceId")
            val email="native-management-${System.currentTimeMillis()}@example.invalid";val password="synthetic-cross-password-only"
            val registered=execute("register",mapOf("email" to email,"password" to password));assertTrue(registered.getBoolean("ok"));val registration=registered.getJSONObject("data")
            val mails=JSONArray(https("/test/emails"));var proof:JSONObject?=null
            for(i in 0 until mails.length()){val mail=mails.getJSONObject(i);if(mail.getString("to")==email)for(line in mail.getString("text").split('\n'))if(Regex("^[2-9A-HJ-NP-Z]{8}$").matches(line))proof=JSONObject().put("accountId",registration.getString("accountId")).put("accountGeneration",registration.getString("accountGeneration")).put("code",line)}
            assertNotNull(proof);assertTrue(execute("verifyEmail",listOf("accountId","accountGeneration","code").associateWith{proof!!.getString(it)}).getBoolean("ok"))
            val began=execute("beginInitialization",mapOf("email" to email,"password" to password,"name" to "管理合成环境","id" to "native-management-root"));assertTrue(began.getBoolean("ok"))
            val view=execute("completeInitialization",mapOf("recoveryCode" to began.getString("recoveryCode"))).getJSONObject("data")
            val env=view.getJSONArray("environments").getJSONObject(0).getString("id")
            assertTrue(execute("setVariable",mapOf("environmentId" to env,"name" to "SYNTHETIC_CROSS","value" to "synthetic-cross-value","id" to "native-management-bootstrap-value")).getBoolean("ok"))
            val socketName=InstrumentationRegistry.getArguments().getString("nativeSocket")!!
            val expiry=(System.currentTimeMillis()/1000+3600).toString()
            NativeManagementTestSocket(socketName){JSONObject().put("email",email).put("approver",device).put("environment",env).put("expiry",expiry.toLong())}.use {socket ->
                Log.i("HarmoniaNativeTest","AWAIT_MANAGEMENT_PEER_SOCKET:cert3-go-peer")
                var subject=""
                socket.nextPacket().use {packet ->
                    assertEquals(env,packet.environment)
                    val choices=JSONArray().put(JSONObject().put("environmentId",env).put("role","rw").put("expiresAt",packet.expiry.toString()))
                    val incoming=packet.shortCode.copyOf()
                    val approved=request(plugin,"executeApproval",mapOf("command" to command("approvePairingV5",mapOf("pairingId" to packet.pairingId,"selections" to choices.toString())),"shortCode" to incoming),"approve-management-peer")
                    packet.shortCode.fill(0);assertTrue(incoming.all{it==0.toByte()});assertTrue(approved.getBoolean("ok"))
                    subject=approved.getJSONObject("data").getString("deviceId");assertNotEquals(device,subject)
                    packet.acknowledge("APPROVED");socket.awaitVerifiedPeerStage()
                    assertTrue(execute("retryApprovalV5",mapOf("pairingId" to packet.pairingId)).getBoolean("ok"))
                }
                socket.control().use {control ->
                    fun grant(id:String,role:String)=execute("prepareDeviceGrant",mapOf("environmentId" to env,"subjectDeviceId" to subject,"role" to role,"expiresAt" to if(role=="none")"0" else expiry,"id" to id))
                    fun row():JSONObject {
                        val rows=execute("managementDevices",mapOf("environmentId" to env)).getJSONArray("data")
                        for(i in 0 until rows.length()){
                            val r=rows.getJSONObject(i)
                            assertEquals(setOf("deviceId","role","expiresAt","keyVersion","grantGeneration"),r.keys().asSequence().toSet())
                            if(r.getString("deviceId")==subject)return r
                        };error("verified management subject missing")
                    }
                    assertEquals("rw",row().getString("role"));assertEquals(0,counter("grants"))
                    val canceled="native-management-cancel"
                    assertEquals("prepared",grant(canceled,"ro").getJSONObject("data").getString("state"));hidden()
                    assertTrue(execute("cancelManagement",mapOf("id" to canceled)).getBoolean("ok"))
                    assertEquals("none",execute("managementInfo").getJSONObject("data").getString("state"))
                    assertEquals("ID_CONFLICT",grant(canceled,"ro").getString("code"));assertEquals(0,counter("grants"))
                    val barrier="native-management-barrier"
                    assertTrue(grant(barrier,"ro").getBoolean("ok"));saves.set(0);failAt=2
                    val rejected=execute("retryManagement",mapOf("id" to barrier));failAt=0
                    assertFalse(rejected.getBoolean("ok"));assertFalse(rejected.getJSONObject("data").getBoolean("applied"));assertEquals(2,saves.get());assertEquals(0,counter("grants"))
                    val prepared=execute("managementInfo").getJSONObject("data");assertEquals("prepared",prepared.getString("state"));assertFalse(prepared.getBoolean("attempted"))
                    assertTrue(execute("cancelManagement",mapOf("id" to barrier)).getBoolean("ok"))
                    val ro="native-management-ro"
                    assertTrue(grant(ro,"ro").getBoolean("ok"));saves.set(0);failAt=5
                    val incomplete=execute("retryManagement",mapOf("id" to ro));failAt=0
                    assertFalse(incomplete.getBoolean("ok"));assertEquals("PENDING",incomplete.getString("code"));assertTrue(incomplete.getJSONObject("data").getBoolean("accepted"));assertFalse(incomplete.getJSONObject("data").getBoolean("applied"));assertEquals(5,saves.get());assertEquals(1,counter("grants"))
                    assertEquals("accepted-not-applied",execute("managementInfo").getJSONObject("data").getString("state"));hidden()
                    instrumentation.runOnMainSync{plugin.dispose()};connect()
                    val completed=execute("retryManagement",mapOf("id" to ro));assertTrue(completed.getBoolean("ok"));assertTrue(completed.getJSONObject("data").getBoolean("applied"));assertEquals(1,counter("grants"))
                    control.verify("ro",completed.getJSONObject("data").getLong("sequence"))
                    val rw="native-management-rw"
                    assertTrue(grant(rw,"rw").getBoolean("ok"));https("/test/control",JSONObject().put("lose","grant"))
                    val unknown=execute("retryManagement",mapOf("id" to rw));assertFalse(unknown.getBoolean("ok"));assertEquals("PENDING",unknown.getString("code"));assertTrue(unknown.getJSONObject("data").getBoolean("acceptanceUnknown"));assertFalse(unknown.getJSONObject("data").getBoolean("applied"));assertEquals(2,counter("grants"))
                    val pending=execute("managementInfo").getJSONObject("data");assertEquals(rw,pending.getString("id"));assertTrue(pending.getBoolean("attempted"));hidden()
                    assertFalse(execute("cancelManagement",mapOf("id" to rw)).getBoolean("ok"))
                    instrumentation.runOnMainSync{plugin.dispose()};connect()
                    val restored=execute("retryManagement",mapOf("id" to rw));assertTrue(restored.getBoolean("ok"));assertTrue(restored.getJSONObject("data").getBoolean("applied"));assertEquals(2,counter("grants"))
                    assertTrue(execute("retryManagement",mapOf("id" to ro)).getBoolean("ok"));assertEquals(2,counter("grants"));assertEquals("rw",row().getString("role"))
                    control.verify("rw",restored.getJSONObject("data").getLong("sequence"))
                    assertEquals("synthetic-management-value",execute("pull").getJSONObject("data").getJSONArray("environments").getJSONObject(0).getJSONObject("variables").getString("SYNTHETIC_MANAGEMENT"))
                    val none="native-management-none"
                    assertTrue(grant(none,"none").getBoolean("ok"));val removed=execute("retryManagement",mapOf("id" to none));assertTrue(removed.getBoolean("ok"));assertTrue(removed.getJSONObject("data").getBoolean("applied"));assertEquals(3,counter("grants"))
                    control.verify("none",removed.getJSONObject("data").getLong("sequence"))
                    val old=row();assertEquals("none",old.getString("role"));val oldGeneration=old.getString("grantGeneration").toLong()
                    assertTrue(execute("rotateEnvironmentKey",mapOf("environmentId" to env,"id" to "native-management-rotate")).getBoolean("ok"))
                    val regrant="native-management-regrant"
                    assertTrue(grant(regrant,"ro").getBoolean("ok"));val added=execute("retryManagement",mapOf("id" to regrant));assertTrue(added.getBoolean("ok"));assertTrue(added.getJSONObject("data").getBoolean("applied"));assertEquals(4,counter("grants"))
                    val current=row();assertEquals("ro",current.getString("role"));assertEquals("2",current.getString("keyVersion"));assertTrue(current.getString("grantGeneration").toLong()>oldGeneration)
                    control.verify("ro-newkey",added.getJSONObject("data").getLong("sequence"))
                    val revoke="native-management-other-revoke"
                    val preparedRevocation=execute("prepareOtherDeviceRevocation",mapOf("environmentId" to env,"subjectDeviceId" to subject,"id" to revoke));assertTrue(preparedRevocation.getBoolean("ok"));assertEquals("prepared",preparedRevocation.getJSONObject("data").getString("state"));assertFalse(preparedRevocation.getJSONObject("data").getBoolean("attempted"));assertEquals(0,counter("revocations"))
                    instrumentation.runOnMainSync{plugin.dispose()};connect()
                    val revoked=execute("retryManagement",mapOf("id" to revoke));assertTrue(revoked.getBoolean("ok"));assertTrue(revoked.getJSONObject("data").getBoolean("accepted"));assertTrue(revoked.getJSONObject("data").getBoolean("applied"));assertEquals(1,counter("revocations"))
                    control.verify("revoked",revoked.getJSONObject("data").getLong("sequence"))
                }
            }
            assertTrue(execute("logout").getBoolean("ok"));assertFalse(store.exists());assertFalse(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
        } finally {failAt=0;instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
}
