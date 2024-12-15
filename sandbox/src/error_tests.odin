package spelmotor_sandbox

import "core:fmt"
import "sm:core"

Test_Err_Data  :: distinct uintptr
Test_Err_Data2 :: distinct uintptr
Test_Result  :: #type core.Result(Test_Err_Data)
Test_Error   :: #type core.Error(Test_Err_Data)
Test_Result2 :: #type core.Result(union #no_nil{Test_Err_Data, Test_Err_Data2})
Test_Error2  :: #type core.Error(union #no_nil{Test_Err_Data, Test_Err_Data2})

error_result_test_low :: proc(i: int) -> (val: int, result: Test_Result) {
	if i > 1000 {
		result = core.error_make(Test_Err_Data(i), "Message")
		return
	}
	val = i
	return
}

error_result_test_high :: proc(i: int) -> (val: int, result: Test_Result) {
	res: Test_Result
	if val, res = error_result_test_low(i); res != nil {
		result = core.result_augment(res, "High level message")
	}
	return
}

error_result_test_higher :: proc(i: int) -> (val: int, result: Test_Result) {
	res: Test_Result
	if val, res = error_result_test_high(i); res != nil {
		result = core.result_augment(res, "Even higher level message %i", res.(Test_Error).data)
	}
	return
}

error_result_test_passthrough :: proc(i: int) -> (val: int, result: Test_Result) {
	val = error_result_test_higher(i) or_return
	return
}

error_result_test_return_cast :: proc(i: int) -> (val: int, result: Test_Result2) {
	if val, res := error_result_test_high(i); res != nil {
		result = core.result_cast(Test_Result2, res)
		return
	}
	return
}

error_result_test_adv :: proc(i: int) -> (val: int, result: Test_Result2) {
	if i > 1000 {
		result = core.error_make_as(Test_Error2, Test_Err_Data(i), "Message")
		return
	}

	val = i
	return
}

test_errors :: proc() {
	v, v1, v2: int
	res: Test_Result
	res2: Test_Result2

	if v, res = error_result_test_high(6000); res != nil {
		err := res.(Test_Error)
		fmt.println("Err_Result:", err, err.location)
	}

	v1, res = error_result_test_higher(4000)
	// core.result_verify(res) // <-- Crash the program on error

	if v, res2 = error_result_test_return_cast(2000); res != nil {
		core.result_log(res2)
	}

	if v2, res2 = error_result_test_adv(10000); res != nil {
		core.result_log(res)
		// Handle the error
		// ...

		err := res2.(Test_Error2)
		// Advanced conditional error handling by data variant:
		switch v in err.data {
		case Test_Err_Data:
			// Handle the error
			// ...
		case Test_Err_Data2:
			// Handle the other error
			// ...
		// Panic otherwise (which should not happen if the type is a 'union' and not an 'any'):
		case: core.error_panic(err)
		}
	}
}
