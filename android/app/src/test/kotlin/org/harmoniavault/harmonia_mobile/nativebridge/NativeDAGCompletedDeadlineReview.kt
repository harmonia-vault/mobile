package org.harmoniavault.harmonia_mobile.nativebridge

internal object NativeDAGCompletedDeadlineReview {
 @JvmStatic fun main(args: Array<String>) {
  var failed=0
  for (mode in listOf("operation-deadline", "auth-deadline")) {
   var now=1000L
   val lifecycle=NativeSlotLifecycle({now},{_,_->NativeSlotTimer{}},41,{})
   lifecycle.onResumed(true)
   val cipher=Any()
   val ticket=lifecycle.prepareAuthentication(cipher,1)
   lifecycle.authenticationStarted(ticket)
   if(mode=="auth-deadline")now=ticket.authDeadline-2000
   lifecycle.authenticationSucceeded(ticket,cipher)
   val permit=lifecycle.consume(ticket)
   val originalDeadline=ticket.deadline
   now=originalDeadline-1
   lifecycle.complete(permit)
   check(lifecycle.canDeliverCompleted(permit)) {"positive precondition failed"}
   // Native cleanup remains asynchronous after complete. Model a release arriving exactly at the original deadline.
   now=originalDeadline
   if(lifecycle.canDeliverCompleted(permit)) {
    failed++;println("FAIL "+mode+": completed result accepted at original deadline after delayed release")
   }else println("PASS "+mode+": expired completed result rejected")
  }
  check(failed==0) {"expired completed result accepted in "+failed+" cases"}
 }
}
