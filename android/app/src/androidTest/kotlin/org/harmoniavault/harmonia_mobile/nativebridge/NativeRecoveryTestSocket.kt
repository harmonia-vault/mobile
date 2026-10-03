package org.harmoniavault.harmonia_mobile.nativebridge

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.system.Os
import android.system.OsConstants
import android.system.StructTimeval
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.Closeable

/** 完整码只在本机socket内存；metadata仅合成email和环境id，无任何钥/码/token。 */
internal class NativeRecoveryTestSocket(name:String):Closeable {
 private val server=LocalServerSocket(name)
 init{Os.setsockoptTimeval(server.fileDescriptor,OsConstants.SOL_SOCKET,OsConstants.SO_RCVTIMEO,StructTimeval.fromMillis(180000))}
 class Packet(val metadata:JSONObject,val code:ByteArray,private val socket:LocalSocket):Closeable {
  fun retainDisplayedNewCode(bytes:ByteArray){
   check(bytes.size in 1..1024)
   val out=DataOutputStream(socket.outputStream);out.write("HARMRN01".toByteArray(Charsets.US_ASCII));out.writeShort(bytes.size);out.write(bytes);out.flush()
   check(DataInputStream(socket.inputStream).readLine()=="NEW_CODE_HELD")
  }
  fun acknowledge(state:String){
   check(state in listOf("REGISTRATION_PENDING","RECOVERED_TRUSTED"))
   socket.outputStream.write((state+"\n").toByteArray(Charsets.US_ASCII));socket.outputStream.flush()
  }
  override fun close(){code.fill(0);socket.close()}
  override fun toString()="native recovery test packet (secret omitted)"
 }
 fun packet(phase:Int):Packet {
  check(phase in 1..3)
  val socket=server.accept();socket.soTimeout=180000
  try {
   socket.outputStream.write("READY\n".toByteArray(Charsets.US_ASCII));socket.outputStream.flush()
   val input=DataInputStream(socket.inputStream);val magic=ByteArray(8);input.readFully(magic)
   check(magic.toString(Charsets.US_ASCII)=="HARMRC0"+phase)
   val n=input.readUnsignedShort();check(n in 1..2048);val raw=ByteArray(n);input.readFully(raw)
   val meta=JSONObject(raw.toString(Charsets.UTF_8));raw.fill(0)
   check(meta.keys().asSequence().toSet()==setOf("email","x","y"))
   check(meta.getString("email").endsWith("@example.invalid"))
   for(key in listOf("x","y"))check(meta.getString(key).matches(Regex("[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")))
   val length=input.readUnsignedShort();check(if(phase==3)length==0 else length in 1..1024)
   val code=ByteArray(length)
   try{input.readFully(code);return Packet(meta,code,socket)}catch(error:Exception){code.fill(0);throw error}
  }catch(error:Exception){socket.close();throw error}
 }
 override fun close(){server.close()}
}
