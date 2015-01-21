;;; Copyright (c) 2015 Ivan Shvedunov
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;; of this software and associated documentation files (the "Software"), to deal
;;; in the Software without restriction, including without limitation the rights
;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;; copies of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be included in
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;;; THE SOFTWARE.

(in-package :cl-mqtt.tests)

(define-fixture interop-fixture () ())

#++
(setf blackbird:*promise-finish-hook*
      #'(lambda (fn)
          (as:with-delay () (funcall fn))))
#++
(defmethod run-fixture-test-case :around ((fixture interop-fixture) test-case teardown-p debug-p)
  (with-broker (host port)
    (call-next-method)))

(deftest test-connect () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host
                                  :port port
                                  :error-handler error-cb)))
      (mqtt:disconnect conn))))

(deftest test-subscribe () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host :port port :error-handler error-cb)))
      (flet ((sub (topic requested-qos expected-mid)
               (bb:multiple-promise-bind (qos mid)
                   (apply #'mqtt:subscribe conn topic
                          (when requested-qos (list requested-qos)))
                 (is (= (or requested-qos 2) qos))
                 (is (= expected-mid mid)))))
        (bb:walk
          (sub "/a/b" 0 1)
          (sub "/c/d" 1 2)
          (sub "/e/f" 2 3)
          (sub "/c/d" nil 4)
          (mqtt:disconnect conn))))))

(define-constant +long-str+ (make-string 128 :initial-element #\X) :test #'equal)

(defun verify-publish (qos)
  (with-broker (host port error-cb)
    (let ((messages '()))
      (flet ((connect ()
               (mqtt:connect host
                             :port port
                             :error-handler error-cb
                             :on-message
                             #'(lambda (message)
                                 (dbg "on-messsage: ~s" message)
                                 (is (= qos (mqtt:mqtt-message-qos message)))
                                 (push (list (mqtt:mqtt-message-topic message)
                                             (babel:octets-to-string
                                              (mqtt:mqtt-message-payload message)
                                              :encoding :utf-8)
                                             (mqtt:mqtt-message-retain message)
                                             (mqtt:mqtt-message-mid message))
                                       messages))))
             (verify-messages (expected-messages)
               (when (zerop qos)
                 ;; in case of QoS=0, replace mids in expected messages with zeroes
                 (setf expected-messages
                       (iter (for (topic payload retain mid) in expected-messages)
                             (collect (list topic payload retain 0)))))
               (let ((actual-messages (nreverse (shiftf messages nil))))
                 (is (equal expected-messages actual-messages)))))
        (bb:alet ((conn (connect)))
          (bb:walk (mqtt:subscribe conn "/a/#")
            (bb:all
             (list
              (mqtt:publish conn "/a/b/c" "42" :qos qos :retain nil)
              (mqtt:publish conn "/a/b/c" +long-str+ :qos qos :retain nil)))
            (bb:wait (wait-for messages)
              (verify-messages `(("/a/b/c" "42" nil 1)
                                 ("/a/b/c" ,+long-str+ nil 2)))
              (bb:wait
                  (mqtt:publish conn "/a/b/d" "4242" :qos qos :retain t)
                ;; expected-retain is still NIL.
                ;; The broker publishes the message back without the retain bit
                ;; because it isn't published as the result of new subscription.
                (bb:wait (wait-for messages)
                  (verify-messages '(("/a/b/d" "4242" nil 3)))
                  ;; reconnect and look for the retained message
                  (bb:wait (mqtt:disconnect conn)
                    (bb:alet ((conn (connect)))
                      (bb:walk
                        (mqtt:subscribe conn "/a/#")
                        (bb:wait (wait-for messages)
                          (verify-messages '(("/a/b/d" "4242" t 1)))
                          (mqtt:disconnect conn))))))))))))))

(deftest test-publish-qos0 () (interop-fixture)
  (verify-publish 0))

(deftest test-publish-qos1 () (interop-fixture)
  (verify-publish 1))

(deftest test-publish-qos2 () (interop-fixture)
  (verify-publish 2))

(deftest test-unsubscribe () (interop-fixture)
  (with-broker (host port error-cb)
    (let ((messages '()))
      (bb:alet ((conn (mqtt:connect host
                                    :port port
                                    :error-handler error-cb
                                    :on-message #'(lambda (message)
                                                    (push (babel:octets-to-string
                                                           (mqtt:mqtt-message-payload message)
                                                           :encoding :utf-8)
                                                          messages)))))
        (bb:walk
          (mqtt:subscribe conn "/a/#")
          (mqtt:subscribe conn "/b/#")
          (mqtt:unsubscribe conn "/a/#")
          (mqtt:publish conn "/a/b" "whatever")
          (mqtt:publish conn "/b/c" "foobar")
          ;; "foobar" goes after whatever, so, if "foobar" was received,
          ;; "whatever" is already skipped
          (wait-for messages)
          (is (equal '("foobar") messages)))))))

(deftest test-ping () (interop-fixture)
  (with-broker (host port error-cb)
    (bb:alet ((conn (mqtt:connect host :port port :error-handler error-cb)))
      (mqtt:ping conn))))

;; TBD: test overlong messages
;; TBD: use 'observe'
;; TBD: multi-topic subscriptions
;; TBD: :event-cb for CONNECT is just TOO wrong
;; TBD: an option auto text decoding for payload (but handle babel decoding errors!)
;; TBD: unclean session
;; TBD: will

;; Separate tests with fake broker (non-interop):
;; TBD: failed connection (to an 'available' port)
;; TBD: dup packets
;; TBD: handle MQTT-ERRORs during message parsing (disconnect)
;; TBD: handle pings from server
;; TBD: max number of inflight messages
;; TBD: subscribe errors
