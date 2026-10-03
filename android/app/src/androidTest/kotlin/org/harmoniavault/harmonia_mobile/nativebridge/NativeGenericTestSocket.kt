package org.harmoniavault.harmonia_mobile.nativebridge

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.system.Os
import android.system.OsConstants
import android.system.StructTimeval
import org.json.JSONObject
import java.io.DataInputStream
import java.io.Closeable

/** 仅instrumentation本机控制面，未加入应用发布源码；短码不JSON、不日志、不文件。 */
internal class NativeGenericTestSocket(name: String, private val metadata: () -> JSONObject) : Closeable {
    private val server = LocalServerSocket(name)
    init { Os.setsockoptTimeval(server.fileDescriptor, OsConstants.SOL_SOCKET, OsConstants.SO_RCVTIMEO, StructTimeval.fromMillis(150000)) }
    internal class Packet(val pairingId: String, val environment: String, val expiry: Long,
                          val shortCode: ByteArray, private val socket: LocalSocket) : Closeable {
        fun acknowledge(state: String) {
            check(state in listOf("APPROVED", "UNKNOWN", "REJECTED", "RECEIVED"))
            socket.outputStream.write((state+"\n").toByteArray(Charsets.US_ASCII)); socket.outputStream.flush()
        }
        override fun close() { shortCode.fill(0); socket.close() }
        override fun toString() = "native pairing test packet (secret omitted)"
    }
    private fun publicString(input: DataInputStream, max: Int): String {
        val length=input.readUnsignedShort();check(length in 1..max)
        val bytes=ByteArray(length);input.readFully(bytes)
        val text=bytes.toString(Charsets.US_ASCII);check(text.matches(Regex("[A-Za-z0-9][A-Za-z0-9._:-]*")))
        return text
    }
    class Enrollment(val metadata: JSONObject, val code: ByteArray, private val socket: LocalSocket): Closeable {
        fun candidateCompleted() {
            socket.outputStream.write("CANDIDATE_COMPLETED\n".toByteArray(Charsets.US_ASCII))
            val response=socket.inputStream.bufferedReader(Charsets.US_ASCII).readLine()
            check(response=="ROOT_COMPLETE")
        }
        override fun close() { code.fill(0); socket.close() }
    }
    fun nextEnrollment(): Enrollment {
        val socket=server.accept();socket.soTimeout=135000
        val code=ByteArray(8)
        try {
            val input=DataInputStream(socket.inputStream);val magic=ByteArray(8);input.readFully(magic)
            check(magic.toString(Charsets.US_ASCII)=="HARMEN03")
            val n=input.readUnsignedShort();check(n in 1..2048)
            val bytes=ByteArray(n);input.readFully(bytes);val metadata=JSONObject(bytes.toString(Charsets.UTF_8))
            check(metadata.length()==5 && listOf("email","approver","x","y","pairingId").all{metadata.has(it)})
            input.readFully(code);check(code.all{it>=48 && it<=57})
            return Enrollment(metadata,code,socket)
        } catch(error:Exception) {code.fill(0);socket.close();throw error}
    }
    fun nextPacket(): Packet {
        while (true) {
            val socket=server.accept(); socket.soTimeout=140000
            try {
                val input=DataInputStream(socket.inputStream);val magic=ByteArray(8);input.readFully(magic)
                when(magic.toString(Charsets.US_ASCII)) {
                    "HARMQR01" -> {
                        val public=metadata().toString();check(public.length<2048)
                        socket.outputStream.write((public+"\n").toByteArray(Charsets.US_ASCII));socket.close()
                    }
                    "HARMPR01" -> {
                        val id=publicString(input,64);val env=publicString(input,128)
                        val expiry=input.readLong();check(expiry>System.currentTimeMillis()/1000 && expiry<=System.currentTimeMillis()/1000+86400)
                        check(input.readUnsignedByte()==2) // 本合成跨端明确只rw。
                        val code=ByteArray(8)
                        try { input.readFully(code);check(code.all {it>=48 && it<=57});return Packet(id,env,expiry,code,socket) }
                        catch(error:Exception) {code.fill(0);throw error}
                    }
                    else -> error("invalid local test frame")
                }
            } catch(error:Exception) {socket.close();throw error}
        }
    }
    fun awaitCompiledCLIStage() {
        server.accept().use {socket ->
            socket.soTimeout=20000;val magic=ByteArray(8);DataInputStream(socket.inputStream).readFully(magic)
            check(magic.toString(Charsets.US_ASCII)=="HARMDN01")
            check(socket.inputStream.read()==1) // host完整验收成功，故障不会假报阶段完成。
            socket.outputStream.write("OK\n".toByteArray(Charsets.US_ASCII))
        }
    }
    override fun close() { server.close() }
}
