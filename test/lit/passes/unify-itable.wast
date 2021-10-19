;; NOTE: Assertions have been generated by update_lit_checks.py --all-items and should not be edited.
;; NOTE: This test was ported using port_test.py and could be cleaned up.

;; RUN: foreach %s %t wasm-opt --nominal --unify-itable --remove-unused-module-elements -all -S -o - | filecheck %s
;; remove-unused-module elements makes it easier to read the output as it
;; removes things no longer needed.

(module
  ;; A module with a single itable that contains several categories of
  ;; different sizes, some of them null. The changes to look for:
  ;;  * The global will switch to contain a base (of 0, which is where the
  ;;    single itable begins.
  ;;  * A table is added, containing the various functions in the itable in
  ;;    order. No padding happens here, as with a single itable each category
  ;;    is of the size it appears in that itable.
  ;;  * call_ref is replaced by a call_indirect with a proper offset, that
  ;;    takes into account the category as well as the offset in that category.

  ;; CHECK:      (type $object (struct_subtype (field $itable i32) data))

  ;; CHECK:      (type $none_=>_none (func_subtype func))
  (type $none_=>_none (func_subtype func))

  (type $itable (array (mut (ref null data))))

  (type $vtable-1 (struct (field (ref $none_=>_none))))
  (type $vtable-2 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none))))
  (type $vtable-3 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none)) (field (ref $none_=>_none))))

  (type $object (struct (field $itable (ref $itable))))

  ;; CHECK:      (type $ref|$object|_=>_none (func_subtype (param (ref $object)) func))

  ;; CHECK:      (type $none_=>_none (func_subtype func))

  ;; CHECK:      (type $none_=>_ref|$object| (func_subtype (result (ref $object)) func))

  ;; CHECK:      (global $itable-1 i32 (i32.const 0))
  (global $itable-1 (ref $itable) (array.init_static $itable
    ;; Category #0, of size 0.
    (ref.null data)
    ;; Category #1, of size 1. This will have base 0.
    (struct.new $vtable-1
      (ref.func $a)
    )
    ;; Category #2, of size 2. This will have base 1.
    (struct.new $vtable-2
      (ref.func $b)
      (ref.func $c)
    )
    ;; Category #3, of size 0.
    (ref.null data)
    ;; Category #4, of size 3. This will have base 3.
    (struct.new $vtable-3
      (ref.func $d)
      (ref.func $e)
      (ref.func $f)
    )
    ;; Category #5, of size 1. This will have base 6.
    (struct.new $vtable-1
      (ref.func $g)
    )
  ))


  ;; CHECK:      (table $unified-table 7 7 funcref)

  ;; CHECK:      (elem (i32.const 0) $a $b $c $d $e $f $g)

  ;; CHECK:      (export "new-1" (func $new-1))

  ;; CHECK:      (export "call-1-0" (func $call-1-0))

  ;; CHECK:      (export "call-2-0" (func $call-2-0))

  ;; CHECK:      (export "call-2-1" (func $call-2-1))

  ;; CHECK:      (export "call-4-0" (func $call-4-0))

  ;; CHECK:      (export "call-4-2" (func $call-4-2))

  ;; CHECK:      (export "call-5-0" (func $call-5-0))

  ;; CHECK:      (func $new-1 (result (ref $object))
  ;; CHECK-NEXT:  (struct.new $object
  ;; CHECK-NEXT:   (global.get $itable-1)
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $new-1 (export "new-1") (result (ref $object))
    (struct.new $object
      (global.get $itable-1)
    )
  )

  ;; CHECK:      (func $call-1-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 0)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-0 (export "call-1-0") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 0 in that category. Added to the category base, we get
      ;; 0 which is what will be added before the call_indirect.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            ;; Call the first category that has any content, #1. The category
            ;; base is 0.
            (i32.const 1)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 1)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-0 (export "call-2-0") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 0 in that category, for a total of 1 added to the
      ;; call_indirect.
      (struct.get $vtable-2 0
        (ref.cast_static $vtable-2
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            ;; Call category #2. It has a base of 1, as there was one item
            ;; in the only category before it.
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-1 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 2)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1 (export "call-2-1") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 1 compared to before, for a total of 2.
      (struct.get $vtable-2 1
        (ref.cast_static $vtable-2
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-4-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 3)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-4-0 (export "call-4-0") (param $ref (ref $object))
    ;; Call category #4, which has base 3, with offset 0.
    (call_ref
      (struct.get $vtable-3 0
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 4)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-4-2 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 5)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-4-2 (export "call-4-2") (param $ref (ref $object))
    ;; Add an offset of 2, for a total of 5.
    (call_ref
      (struct.get $vtable-3 2
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 4)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-5-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 6)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-5-0 (export "call-5-0") (param $ref (ref $object))
    ;; Call category #5, which has base 6, with offset 0.
    (call_ref
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 5)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $a
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $a)
  ;; CHECK:      (func $b
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $b)
  ;; CHECK:      (func $c
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $c)
  ;; CHECK:      (func $d
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $d)
  ;; CHECK:      (func $e
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $e)
  ;; CHECK:      (func $f
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $f)

  ;; CHECK:      (func $g
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $g)
)
