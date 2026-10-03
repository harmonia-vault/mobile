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
internal class NativeManagementTestSocket(name: String, private val metadata: () -> JSONObject) : Closeable {
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
    fun awaitVerifiedPeerStage() {
        server.accept().use {socket ->
            socket.soTimeout=20000;val magic=ByteArray(8);DataInputStream(socket.inputStream).readFully(magic)
            check(magic.toString(Charsets.US_ASCII)=="HARMDN01")
            check(socket.inputStream.read()==1) // host完整验收成功，故障不会假报阶段完成。
            socket.outputStream.write("OK\n".toByteArray(Charsets.US_ASCII))
        }
    }
    internal class Control(private val socket: LocalSocket) : Closeable {
        fun verify(state: String, sequence: Long) {
            check(state in listOf("ro", "rw", "none", "ro-newkey", "revoked") && sequence > 0)
            val public = JSONObject().put("state", state).put("sequence", sequence).toString().toByteArray(Charsets.US_ASCII)
            check(public.size <= 256)
            val output = java.io.DataOutputStream(socket.outputStream)
            output.writeShort(public.size); output.write(public); output.flush()
            check(socket.inputStream.read() == 1) // 仅真实Go权限/Pull断言成功才确认。
        }
        override fun close() { socket.close() }
    }
    fun control(): Control {
        val socket = server.accept(); socket.soTimeout = 240000
        try {
            val magic = ByteArray(8); DataInputStream(socket.inputStream).readFully(magic)
            check(magic.toString(Charsets.US_ASCII) == "HARMCT01")
            return Control(socket)
        } catch (error: Exception) { socket.close(); throw error }
    }
    override fun close() { server.close() }
}
