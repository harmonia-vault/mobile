package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
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
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import java.net.URL

/** 原生业务/强认证验收，只有系统认证提示需要合成PIN交互；不测试或编写Flutter UI。 */
class NativeWorkflowIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val alias = "harmonia/synthetic-workflow-test/v1"
    private val keyFilename = "synthetic-workflow-key.gcm"
    private val stateFilename = "synthetic-workflow-state.gcm"
    private val endpoint = "https://10.0.2.2:4443"
    private val ca = Base64.decode(InstrumentationRegistry.getArguments().getString("syntheticCA")!!, Base64.NO_WRAP)
    private var failSave = false
    private val messenger = object : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private fun cleanup() {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keys.containsAlias(alias)) keys.deleteEntry(alias)
        for (filename in listOf(keyFilename,stateFilename)) {
            val file = File(File(context.noBackupFilesDir,"harmonia"),filename)
            file.delete(); File(file.path+".bak").delete(); File(file.path+".new").delete()
        }
    }
    private class Outcome : MethodChannel.Result {
        val ready = CountDownLatch(1); var value: Any? = null; var code: String? = null
        override fun success(result: Any?) {value=result;ready.countDown()}
        override fun error(errorCode:String,errorMessage:String?,errorDetails:Any?){code=errorCode;ready.countDown()}
        override fun notImplemented(){code="NOT_IMPLEMENTED";ready.countDown()}
    }
    private fun request(plugin:NativeBridgePlugin,method:String,args:Any?,phase:String):JSONObject {
        val out=Outcome()
        instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall(method,args),out)}
        if(phase=="createDevice") {
            val busy=Outcome()
            instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("createDevice",null),busy)}
            assertTrue(busy.ready.await(10,TimeUnit.SECONDS));assertEquals("BUSY",busy.code)
        }
        Log.i("HarmoniaNativeTest","AWAIT_WORKFLOW_AUTH:$phase")
        assertTrue("native authenticated operation timed out",out.ready.await(90,TimeUnit.SECONDS))
        assertNull("native operation rejected: ${out.code}",out.code)
        return JSONObject(out.value as String)
    }
    private fun command(operation:String,fields:Map<String,String> = emptyMap()):String {
        val json=JSONObject().put("version",1).put("operation",operation).put("endpoint",endpoint)
        for ((key,value) in fields) json.put(key,value)
        return json.toString()
    }
    private fun https(path:String,body:JSONObject?=null):String {
        val cert=CertificateFactory.getInstance("X.509").generateCertificate(ca.inputStream())
        val trust=KeyStore.getInstance(KeyStore.getDefaultType()).apply{load(null);setCertificateEntry("synthetic-ca",cert)}
        val factory=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply{init(trust)}
        val tls=SSLContext.getInstance("TLS").apply{init(null,factory.trustManagers,null)}
        val conn=URL(endpoint+path).openConnection() as HttpsURLConnection
        conn.sslSocketFactory=tls.socketFactory;conn.connectTimeout=5000;conn.readTimeout=5000
        if(body!=null){conn.requestMethod="POST";conn.doOutput=true;conn.setRequestProperty("Content-Type","application/json");conn.outputStream.use{it.write(body.toString().toByteArray())}}
        try{assertEquals("synthetic fixture HTTPS failed",200,conn.responseCode);return conn.inputStream.bufferedReader().use{it.readText()}}finally{conn.disconnect()}
    }
    private fun lose(kind:String){https("/test/control",JSONObject().put("lose",kind))}
    private fun checkView(result:JSONObject):JSONObject {assertTrue("verified operation not complete",result.getBoolean("ok"));return result.getJSONObject("data")}

    @Test fun testProtectedRealHTTPSLifecycleResumeAndLogout(){
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename)
        assertTrue("synthetic system credential required",store.supported())
        lateinit var plugin:NativeBridgePlugin
        fun connect(){instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca,beforeWorkflowSave={check(!failSave)})}}
        fun execute(op:String,fields:Map<String,String> = emptyMap(),phase:String=op)=request(plugin,"executeWorkflow",command(op,fields),phase)
        connect()
        try{
            val created=request(plugin,"createDevice",null,"createDevice");assertFalse(created.getBoolean("trusted"))
            val email="android-${System.currentTimeMillis()}@example.invalid";val password="synthetic-native-password-only"
            val registered=execute("register",mapOf("email" to email,"password" to password));assertTrue(registered.getBoolean("ok"))
            val registration=registered.getJSONObject("data");assertTrue(registration.getBoolean("verificationRequired"))
            val mail=JSONArray(https("/test/emails"));var proof:JSONObject?=null
            for(i in 0 until mail.length()){val message=mail.getJSONObject(i);if(message.getString("to")==email){for(line in message.getString("text").split('\n')){if(Regex("^[2-9A-HJ-NP-Z]{8}$").matches(line))proof=JSONObject().put("accountId",registration.getString("accountId")).put("accountGeneration",registration.getString("accountGeneration")).put("code",line)}}}
            assertNotNull("synthetic verification proof missing",proof)
            assertEquals(registration.getString("accountId"),proof!!.getString("accountId"))
            val verified=execute("verifyEmail",listOf("accountId","accountGeneration","code").associateWith{proof!!.getString(it)})
            assertTrue(verified.getBoolean("ok"))
            val began=execute("beginInitialization",mapOf("email" to email,"password" to password,"name" to "合成初始环境","id" to "android-init"))
            assertTrue(began.getBoolean("ok"));val code=began.getString("recoveryCode");assertEquals(52,code.length)
            val stateFile=File(File(context.noBackupFilesDir,"harmonia"),stateFilename)
            assertTrue(stateFile.isFile);assertFalse(stateFile.readBytes().toString(Charsets.ISO_8859_1).contains(code))
            lose("init")
            val unknown=execute("completeInitialization",mapOf("recoveryCode" to code),"complete-unknown")
            assertFalse(unknown.getBoolean("ok"));assertEquals("PENDING",unknown.getString("code"))
            instrumentation.runOnMainSync{plugin.dispose()};connect()
            val resumed=checkView(execute("completeInitialization",mapOf("recoveryCode" to code),"complete-resume"))
            assertEquals(1,resumed.getJSONArray("environments").length())
            assertEquals(created.getString("deviceId"),resumed.getString("deviceId"))
            val env=resumed.getJSONArray("environments").getJSONObject(0).getString("id")
            lose("mutation")
            val put=mapOf("environmentId" to env,"name" to "SYNTHETIC_NATIVE","value" to "synthetic-native-value","id" to "android-put")
            val pending=execute("setVariable",put,"put-unknown");assertFalse(pending.getBoolean("ok"));assertEquals("PENDING",pending.getString("code"))
            instrumentation.runOnMainSync{plugin.dispose()};connect()
            val applied=checkView(execute("setVariable",put,"put-resume"))
            assertEquals("synthetic-native-value",applied.getJSONArray("environments").getJSONObject(0).getJSONObject("variables").getString("SYNTHETIC_NATIVE"))
            val repeated=checkView(execute("setVariable",put,"put-same-id"));assertEquals(applied.getLong("checkpoint"),repeated.getLong("checkpoint"))
            val conflict=execute("setVariable",put+mapOf("value" to "changed-synthetic-intent"),"put-conflict")
            assertFalse(conflict.getBoolean("ok"));assertEquals("ID_CONFLICT",conflict.getString("code"))
            val counters=JSONObject(https("/test/counters")).getLong("mutations")
            val previous=stateFile.readBytes();failSave=true
            val failed=execute("setVariable",put+mapOf("id" to "android-save-failure"),"save-failure");assertFalse(failed.getBoolean("ok"));failSave=false
            assertTrue(previous.contentEquals(stateFile.readBytes()));assertEquals(counters,JSONObject(https("/test/counters")).getLong("mutations"))
            val offline=checkView(execute("view"));assertEquals(applied.getLong("checkpoint"),offline.getLong("checkpoint"))
            val envs=checkView(execute("createEnvironment",mapOf("name" to "第二合成环境","id" to "android-create"))).getJSONArray("environments")
            assertEquals(2,envs.length());var second=""
            for(i in 0 until envs.length()){val item=envs.getJSONObject(i);if(item.getString("id")!=env)second=item.getString("id")}
            checkView(execute("renameEnvironment",mapOf("environmentId" to second,"name" to "改名合成环境","id" to "android-rename")))
            checkView(execute("deleteVariable",mapOf("environmentId" to env,"name" to "SYNTHETIC_NATIVE","id" to "android-delete-var")))
            assertEquals(1,checkView(execute("deleteEnvironment",mapOf("environmentId" to second,"id" to "android-delete-env"))).getJSONArray("environments").length())
            assertFalse(stateFile.readBytes().toString(Charsets.ISO_8859_1).contains("synthetic-native-value"))
            val loggedOut=execute("logout");assertTrue(loggedOut.getBoolean("ok"));assertFalse(store.exists());assertFalse(stateFile.exists())
            val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};assertFalse(keys.containsAlias(alias))
            val rejected=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command("view")),rejected)}
            assertTrue(rejected.ready.await(10,TimeUnit.SECONDS));assertEquals("PROTECTED_KEYS_UNAVAILABLE",rejected.code)
        }finally{failSave=false;instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
    @Test fun testWorkflowCancelledAuthenticationDoesNotRegisterOrChangeProtectedState() {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename)
        lateinit var plugin:NativeBridgePlugin
        instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca)}
        try {
            request(plugin,"createDevice",null,"cancel-create")
            val keyFile=File(File(context.noBackupFilesDir,"harmonia"),keyFilename)
            val previous=keyFile.readBytes()
            val emailsBefore=JSONArray(https("/test/emails")).length()
            val out=Outcome()
            instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command("register",mapOf("email" to "cancelled@example.invalid","password" to "synthetic-cancelled-password"))),out)}
            Log.i("HarmoniaNativeTest","AWAIT_WORKFLOW_AUTH:cancel-workflow")
            assertTrue(out.ready.await(60,TimeUnit.SECONDS));assertEquals("AUTH_CANCELLED",out.code);assertNull(out.value)
            assertTrue(previous.contentEquals(keyFile.readBytes()))
            assertFalse(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
            assertEquals(emailsBefore,JSONArray(https("/test/emails")).length())
        } finally {instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }

    @Test fun testUntrustedTLSChainCannotRegister() {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename)
        lateinit var plugin:NativeBridgePlugin
        // 故意不给本机合成CA，不能借其他成功操作或强认证绕过HTTPS证书验证。
        instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename)}
        try {
            request(plugin,"createDevice",null,"tls-create")
            val before=JSONArray(https("/test/emails")).length()
            val rejected=request(plugin,"executeWorkflow",command("register",mapOf("email" to "untrusted-tls@example.invalid","password" to "synthetic-tls-password")),"tls-reject")
            assertFalse(rejected.getBoolean("ok"));assertEquals("REJECTED",rejected.getString("code"))
            assertEquals(before,JSONArray(https("/test/emails")).length())
            assertFalse(File(File(context.noBackupFilesDir,"harmonia"),stateFilename).exists())
        } finally {instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }

    private fun runSelfRevocation(unknownResult:Boolean) {
        cleanup()
        val activity=instrumentation.startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store=ProtectedDeviceStore(context,alias,keyFilename)
        lateinit var plugin:NativeBridgePlugin
        instrumentation.runOnMainSync{plugin=NativeBridgePlugin(activity,messenger,store,stateFilename,ca)}
        fun execute(op:String,fields:Map<String,String> = emptyMap(),phase:String=op)=request(plugin,"executeWorkflow",command(op,fields),"revoke-"+phase)
        try {
            request(plugin,"createDevice",null,"revoke-create")
            val email="revoke-${System.currentTimeMillis()}@example.invalid";val password="synthetic-revocation-password"
            val registered=execute("register",mapOf("email" to email,"password" to password));assertTrue(registered.getBoolean("ok"));val registration=registered.getJSONObject("data")
            val emails=JSONArray(https("/test/emails"));var proof:JSONObject?=null
            for(i in 0 until emails.length()){val mail=emails.getJSONObject(i);if(mail.getString("to")==email){for(line in mail.getString("text").split('\n')){if(Regex("^[2-9A-HJ-NP-Z]{8}$").matches(line))proof=JSONObject().put("accountId",registration.getString("accountId")).put("accountGeneration",registration.getString("accountGeneration")).put("code",line)}}}
            assertNotNull(proof)
            assertTrue(execute("verifyEmail",listOf("accountId","accountGeneration","code").associateWith{proof!!.getString(it)}).getBoolean("ok"))
            val began=execute("beginInitialization",mapOf("email" to email,"password" to password,"name" to "撤销合成环境","id" to "native-revoke-init"))
            assertTrue(began.getBoolean("ok"));checkView(execute("completeInitialization",mapOf("recoveryCode" to began.getString("recoveryCode"))))
            val stateFile=File(File(context.noBackupFilesDir,"harmonia"),stateFilename)
            if(unknownResult) lose("revocation")
            val first=execute("revokeSelf",mapOf("id" to "native-self-revoke"),"self-first")
            val firstResult=first.getJSONObject("data")
            if(unknownResult) {
                assertFalse(first.getBoolean("ok"));assertEquals("PENDING",first.getString("code"))
                assertFalse(firstResult.getBoolean("completed"));assertTrue(firstResult.getBoolean("acceptanceUnknown"))
                assertTrue(store.exists());assertTrue(stateFile.exists())
                val pendingInfo=execute("selfRevocationInfo",phase="pending-info").getJSONObject("data")
                assertEquals("pending",pendingInfo.getString("state"));assertEquals("native-self-revoke",pendingInfo.getString("id"))
                val hidden=execute("view",phase="pending-view")
                assertFalse(hidden.getBoolean("ok"));assertFalse(hidden.has("data"))
                // 新Go对象从密文pending原bundle/token恢复，先同id查询；失效不能假报接受回执。
                val invalidated=execute("revokeSelf",mapOf("id" to "native-self-revoke"),"self-resume")
                assertFalse(invalidated.getBoolean("ok"));assertEquals("TRUST_INVALIDATED",invalidated.getString("code"))
                val result=invalidated.getJSONObject("data")
                assertTrue(result.getBoolean("deviceInvalidated"));assertTrue(result.getBoolean("acceptanceUnknown"));assertFalse(result.getBoolean("completed"))
            } else {
                assertTrue(first.getBoolean("ok"));assertTrue(firstResult.getBoolean("completed"))
                assertTrue(firstResult.getBoolean("deviceInvalidated"));assertFalse(firstResult.getBoolean("acceptanceUnknown"))
                assertTrue(firstResult.getLong("sequence")>0)
            }
            assertFalse(store.exists());assertFalse(stateFile.exists())
            val keys=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};assertFalse(keys.containsAlias(alias))
            val stopped=Outcome();instrumentation.runOnMainSync{plugin.onMethodCall(MethodCall("executeWorkflow",command("view")),stopped)}
            assertTrue(stopped.ready.await(10,TimeUnit.SECONDS));assertEquals("PROTECTED_KEYS_UNAVAILABLE",stopped.code)
        } finally {instrumentation.runOnMainSync{plugin.dispose();activity.finish()};cleanup()}
    }
    @Test fun testSelfRevocationKnownReceiptClearsProtectedDevice()=runSelfRevocation(false)
    @Test fun testSelfRevocationUnknownReceiptInvalidatesWithoutClaimingAccepted()=runSelfRevocation(true)

}
