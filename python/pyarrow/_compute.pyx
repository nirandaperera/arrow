# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# cython: language_level = 3

from cython.operator cimport dereference as deref

from collections import namedtuple

from pyarrow.lib import frombytes, tobytes, ordered_dict
from pyarrow.lib cimport *
from pyarrow.includes.libarrow cimport *
import pyarrow.lib as lib

import numpy as np


cdef wrap_scalar_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ scalar Function in a ScalarFunction object.
    """
    cdef ScalarFunction func = ScalarFunction.__new__(ScalarFunction)
    func.init(sp_func)
    return func


cdef wrap_vector_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ vector Function in a VectorFunction object.
    """
    cdef VectorFunction func = VectorFunction.__new__(VectorFunction)
    func.init(sp_func)
    return func


cdef wrap_scalar_aggregate_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ aggregate Function in a ScalarAggregateFunction object.
    """
    cdef ScalarAggregateFunction func = (
        ScalarAggregateFunction.__new__(ScalarAggregateFunction)
    )
    func.init(sp_func)
    return func


cdef wrap_hash_aggregate_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ aggregate Function in a HashAggregateFunction object.
    """
    cdef HashAggregateFunction func = (
        HashAggregateFunction.__new__(HashAggregateFunction)
    )
    func.init(sp_func)
    return func


cdef wrap_meta_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ meta Function in a MetaFunction object.
    """
    cdef MetaFunction func = (
        MetaFunction.__new__(MetaFunction)
    )
    func.init(sp_func)
    return func


cdef wrap_function(const shared_ptr[CFunction]& sp_func):
    """
    Wrap a C++ Function in a Function object.

    This dispatches to specialized wrappers depending on the function kind.
    """
    if sp_func.get() == NULL:
        raise ValueError('Function was NULL')

    cdef FunctionKind c_kind = sp_func.get().kind()
    if c_kind == FunctionKind_SCALAR:
        return wrap_scalar_function(sp_func)
    elif c_kind == FunctionKind_VECTOR:
        return wrap_vector_function(sp_func)
    elif c_kind == FunctionKind_SCALAR_AGGREGATE:
        return wrap_scalar_aggregate_function(sp_func)
    elif c_kind == FunctionKind_HASH_AGGREGATE:
        return wrap_hash_aggregate_function(sp_func)
    elif c_kind == FunctionKind_META:
        return wrap_meta_function(sp_func)
    else:
        raise NotImplementedError("Unknown Function::Kind")


cdef wrap_scalar_kernel(const CScalarKernel* c_kernel):
    if c_kernel == NULL:
        raise ValueError('Kernel was NULL')
    cdef ScalarKernel kernel = ScalarKernel.__new__(ScalarKernel)
    kernel.init(c_kernel)
    return kernel


cdef wrap_vector_kernel(const CVectorKernel* c_kernel):
    if c_kernel == NULL:
        raise ValueError('Kernel was NULL')
    cdef VectorKernel kernel = VectorKernel.__new__(VectorKernel)
    kernel.init(c_kernel)
    return kernel


cdef wrap_scalar_aggregate_kernel(const CScalarAggregateKernel* c_kernel):
    if c_kernel == NULL:
        raise ValueError('Kernel was NULL')
    cdef ScalarAggregateKernel kernel = (
        ScalarAggregateKernel.__new__(ScalarAggregateKernel)
    )
    kernel.init(c_kernel)
    return kernel


cdef wrap_hash_aggregate_kernel(const CHashAggregateKernel* c_kernel):
    if c_kernel == NULL:
        raise ValueError('Kernel was NULL')
    cdef HashAggregateKernel kernel = (
        HashAggregateKernel.__new__(HashAggregateKernel)
    )
    kernel.init(c_kernel)
    return kernel


cdef class Kernel(_Weakrefable):
    """
    A kernel object.

    Kernels handle the execution of a Function for a certain signature.
    """

    def __init__(self):
        raise TypeError("Do not call {}'s constructor directly"
                        .format(self.__class__.__name__))


cdef class ScalarKernel(Kernel):
    cdef:
        const CScalarKernel* kernel

    cdef void init(self, const CScalarKernel* kernel) except *:
        self.kernel = kernel

    def __repr__(self):
        return ("ScalarKernel<{}>"
                .format(frombytes(self.kernel.signature.get().ToString())))


cdef class VectorKernel(Kernel):
    cdef:
        const CVectorKernel* kernel

    cdef void init(self, const CVectorKernel* kernel) except *:
        self.kernel = kernel

    def __repr__(self):
        return ("VectorKernel<{}>"
                .format(frombytes(self.kernel.signature.get().ToString())))


cdef class ScalarAggregateKernel(Kernel):
    cdef:
        const CScalarAggregateKernel* kernel

    cdef void init(self, const CScalarAggregateKernel* kernel) except *:
        self.kernel = kernel

    def __repr__(self):
        return ("ScalarAggregateKernel<{}>"
                .format(frombytes(self.kernel.signature.get().ToString())))


cdef class HashAggregateKernel(Kernel):
    cdef:
        const CHashAggregateKernel* kernel

    cdef void init(self, const CHashAggregateKernel* kernel) except *:
        self.kernel = kernel

    def __repr__(self):
        return ("HashAggregateKernel<{}>"
                .format(frombytes(self.kernel.signature.get().ToString())))


FunctionDoc = namedtuple(
    "FunctionDoc",
    ("summary", "description", "arg_names", "options_class"))


cdef class Function(_Weakrefable):
    """
    A compute function.

    A function implements a certain logical computation over a range of
    possible input signatures.  Each signature accepts a range of input
    types and is implemented by a given Kernel.

    Functions can be of different kinds:

    * "scalar" functions apply an item-wise computation over all items
      of their inputs.  Each item in the output only depends on the values
      of the inputs at the same position.  Examples: addition, comparisons,
      string predicates...

    * "vector" functions apply a collection-wise computation, such that
      each item in the output may depend on the values of several items
      in each input.  Examples: dictionary encoding, sorting, extracting
      unique values...

    * "scalar_aggregate" functions reduce the dimensionality of the inputs by
      applying a reduction function.  Examples: sum, min_max, mode...

    * "hash_aggregate" functions apply a reduction function to an input
      subdivided by grouping criteria.  They may not be directly called.
      Examples: hash_sum, hash_min_max...

    * "meta" functions dispatch to other functions.
    """
    cdef:
        shared_ptr[CFunction] sp_func
        CFunction* base_func

    def __init__(self):
        raise TypeError("Do not call {}'s constructor directly"
                        .format(self.__class__.__name__))

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        self.sp_func = sp_func
        self.base_func = sp_func.get()

    def __repr__(self):
        return ("arrow.compute.Function<name={}, kind={}, "
                "arity={}, num_kernels={}>"
                ).format(self.name, self.kind, self.arity, self.num_kernels)

    def __reduce__(self):
        # Reduction uses the global registry
        return get_function, (self.name,)

    @property
    def name(self):
        """
        The function name.
        """
        return frombytes(self.base_func.name())

    @property
    def arity(self):
        """
        The function arity.

        If Ellipsis (i.e. `...`) is returned, the function takes a variable
        number of arguments.
        """
        cdef CArity arity = self.base_func.arity()
        if arity.is_varargs:
            return ...
        else:
            return arity.num_args

    @property
    def kind(self):
        """
        The function kind.
        """
        cdef FunctionKind c_kind = self.base_func.kind()
        if c_kind == FunctionKind_SCALAR:
            return 'scalar'
        elif c_kind == FunctionKind_VECTOR:
            return 'vector'
        elif c_kind == FunctionKind_SCALAR_AGGREGATE:
            return 'scalar_aggregate'
        elif c_kind == FunctionKind_HASH_AGGREGATE:
            return 'hash_aggregate'
        elif c_kind == FunctionKind_META:
            return 'meta'
        else:
            raise NotImplementedError("Unknown Function::Kind")

    @property
    def _doc(self):
        """
        The C++-like function documentation (for internal use).
        """
        cdef CFunctionDoc c_doc = self.base_func.doc()

        return FunctionDoc(frombytes(c_doc.summary),
                           frombytes(c_doc.description),
                           [frombytes(s) for s in c_doc.arg_names],
                           frombytes(c_doc.options_class))

    @property
    def num_kernels(self):
        """
        The number of kernels implementing this function.
        """
        return self.base_func.num_kernels()

    def call(self, args, FunctionOptions options=None,
             MemoryPool memory_pool=None):
        """
        Call the function on the given arguments.
        """
        cdef:
            const CFunctionOptions* c_options = NULL
            CMemoryPool* pool = maybe_unbox_memory_pool(memory_pool)
            CExecContext c_exec_ctx = CExecContext(pool)
            vector[CDatum] c_args
            CDatum result

        _pack_compute_args(args, &c_args)

        if options is not None:
            c_options = options.get_options()

        with nogil:
            result = GetResultValue(self.base_func.Execute(c_args,
                                                           c_options,
                                                           &c_exec_ctx))

        return wrap_datum(result)


cdef class ScalarFunction(Function):
    cdef:
        const CScalarFunction* func

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        Function.init(self, sp_func)
        self.func = <const CScalarFunction*> sp_func.get()

    @property
    def kernels(self):
        """
        The kernels implementing this function.
        """
        cdef vector[const CScalarKernel*] kernels = self.func.kernels()
        return [wrap_scalar_kernel(k) for k in kernels]


cdef class VectorFunction(Function):
    cdef:
        const CVectorFunction* func

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        Function.init(self, sp_func)
        self.func = <const CVectorFunction*> sp_func.get()

    @property
    def kernels(self):
        """
        The kernels implementing this function.
        """
        cdef vector[const CVectorKernel*] kernels = self.func.kernels()
        return [wrap_vector_kernel(k) for k in kernels]


cdef class ScalarAggregateFunction(Function):
    cdef:
        const CScalarAggregateFunction* func

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        Function.init(self, sp_func)
        self.func = <const CScalarAggregateFunction*> sp_func.get()

    @property
    def kernels(self):
        """
        The kernels implementing this function.
        """
        cdef vector[const CScalarAggregateKernel*] kernels = (
            self.func.kernels()
        )
        return [wrap_scalar_aggregate_kernel(k) for k in kernels]


cdef class HashAggregateFunction(Function):
    cdef:
        const CHashAggregateFunction* func

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        Function.init(self, sp_func)
        self.func = <const CHashAggregateFunction*> sp_func.get()

    @property
    def kernels(self):
        """
        The kernels implementing this function.
        """
        cdef vector[const CHashAggregateKernel*] kernels = (
            self.func.kernels()
        )
        return [wrap_hash_aggregate_kernel(k) for k in kernels]


cdef class MetaFunction(Function):
    cdef:
        const CMetaFunction* func

    cdef void init(self, const shared_ptr[CFunction]& sp_func) except *:
        Function.init(self, sp_func)
        self.func = <const CMetaFunction*> sp_func.get()

    # Since num_kernels is exposed, also expose a kernels property

    @property
    def kernels(self):
        """
        The kernels implementing this function.
        """
        return []


cdef _pack_compute_args(object values, vector[CDatum]* out):
    for val in values:
        if isinstance(val, (list, np.ndarray)):
            val = lib.asarray(val)

        if isinstance(val, Array):
            out.push_back(CDatum((<Array> val).sp_array))
            continue
        elif isinstance(val, ChunkedArray):
            out.push_back(CDatum((<ChunkedArray> val).sp_chunked_array))
            continue
        elif isinstance(val, Scalar):
            out.push_back(CDatum((<Scalar> val).unwrap()))
            continue
        elif isinstance(val, RecordBatch):
            out.push_back(CDatum((<RecordBatch> val).sp_batch))
            continue
        elif isinstance(val, Table):
            out.push_back(CDatum((<Table> val).sp_table))
            continue
        else:
            # Is it a Python scalar?
            try:
                scal = lib.scalar(val)
            except Exception:
                # Raise dedicated error below
                pass
            else:
                out.push_back(CDatum((<Scalar> scal).unwrap()))
                continue

        raise TypeError("Got unexpected argument type {} "
                        "for compute function".format(type(val)))


cdef class FunctionRegistry(_Weakrefable):
    cdef:
        CFunctionRegistry* registry

    def __init__(self):
        self.registry = GetFunctionRegistry()

    def list_functions(self):
        """
        Return all function names in the registry.
        """
        cdef vector[c_string] names = self.registry.GetFunctionNames()
        return [frombytes(name) for name in names]

    def get_function(self, name):
        """
        Look up a function by name in the registry.
        """
        cdef:
            c_string c_name = tobytes(name)
            shared_ptr[CFunction] func
        with nogil:
            func = GetResultValue(self.registry.GetFunction(c_name))
        return wrap_function(func)


cdef FunctionRegistry _global_func_registry = FunctionRegistry()


def function_registry():
    return _global_func_registry


def get_function(name):
    """
    Get a function by name.

    The function is looked up in the global registry
    (as returned by `function_registry()`).
    """
    return _global_func_registry.get_function(name)


def list_functions():
    """
    Return all function names in the global registry.
    """
    return _global_func_registry.list_functions()


def call_function(name, args, options=None, memory_pool=None):
    """
    Call a named function.

    The function is looked up in the global registry
    (as returned by `function_registry()`).
    """
    func = _global_func_registry.get_function(name)
    return func.call(args, options=options, memory_pool=memory_pool)


cdef class FunctionOptions(_Weakrefable):

    cdef const CFunctionOptions* get_options(self) except NULL:
        raise NotImplementedError("Unimplemented base options")


# NOTE:
# To properly expose the constructor signature of FunctionOptions
# subclasses, we use a two-level inheritance:
# 1. a C extension class that implements option validation and setting
#    (won't expose function signatures because of
#     https://github.com/cython/cython/issues/3873)
# 2. a Python derived class that implements the constructor

cdef class _CastOptions(FunctionOptions):
    cdef:
        unique_ptr[CCastOptions] options

    __slots__ = ()  # avoid mistakingly creating attributes

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.options.get()

    def _set_options(self, DataType target_type, allow_int_overflow,
                     allow_time_truncate, allow_time_overflow,
                     allow_float_truncate, allow_invalid_utf8):
        self.options.reset(new CCastOptions())
        self._set_type(target_type)
        if allow_int_overflow is not None:
            self.allow_int_overflow = allow_int_overflow
        if allow_time_truncate is not None:
            self.allow_time_truncate = allow_time_truncate
        if allow_time_overflow is not None:
            self.allow_time_overflow = allow_time_overflow
        if allow_float_truncate is not None:
            self.allow_float_truncate = allow_float_truncate
        if allow_invalid_utf8 is not None:
            self.allow_invalid_utf8 = allow_invalid_utf8

    def _set_type(self, target_type=None):
        if target_type is not None:
            deref(self.options).to_type = (
                (<DataType> ensure_type(target_type)).sp_type
            )

    def _set_safe(self):
        self.options.reset(new CCastOptions(CCastOptions.Safe()))

    def _set_unsafe(self):
        self.options.reset(new CCastOptions(CCastOptions.Unsafe()))

    def is_safe(self):
        return not (
            deref(self.options).allow_int_overflow or
            deref(self.options).allow_time_truncate or
            deref(self.options).allow_time_overflow or
            deref(self.options).allow_float_truncate or
            deref(self.options).allow_invalid_utf8
        )

    @property
    def allow_int_overflow(self):
        return deref(self.options).allow_int_overflow

    @allow_int_overflow.setter
    def allow_int_overflow(self, bint flag):
        deref(self.options).allow_int_overflow = flag

    @property
    def allow_time_truncate(self):
        return deref(self.options).allow_time_truncate

    @allow_time_truncate.setter
    def allow_time_truncate(self, bint flag):
        deref(self.options).allow_time_truncate = flag

    @property
    def allow_time_overflow(self):
        return deref(self.options).allow_time_overflow

    @allow_time_overflow.setter
    def allow_time_overflow(self, bint flag):
        deref(self.options).allow_time_overflow = flag

    @property
    def allow_float_truncate(self):
        return deref(self.options).allow_float_truncate

    @allow_float_truncate.setter
    def allow_float_truncate(self, bint flag):
        deref(self.options).allow_float_truncate = flag

    @property
    def allow_invalid_utf8(self):
        return deref(self.options).allow_invalid_utf8

    @allow_invalid_utf8.setter
    def allow_invalid_utf8(self, bint flag):
        deref(self.options).allow_invalid_utf8 = flag


class CastOptions(_CastOptions):

    def __init__(self, target_type=None, *, allow_int_overflow=None,
                 allow_time_truncate=None, allow_time_overflow=None,
                 allow_float_truncate=None, allow_invalid_utf8=None):
        self._set_options(target_type, allow_int_overflow,
                          allow_time_truncate, allow_time_overflow,
                          allow_float_truncate, allow_invalid_utf8)

    @staticmethod
    def safe(target_type=None):
        self = CastOptions()
        self._set_safe()
        self._set_type(target_type)
        return self

    @staticmethod
    def unsafe(target_type=None):
        self = CastOptions()
        self._set_unsafe()
        self._set_type(target_type)
        return self


cdef class _MatchSubstringOptions(FunctionOptions):
    cdef:
        unique_ptr[CMatchSubstringOptions] match_substring_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.match_substring_options.get()

    def _set_options(self, pattern, bint ignore_case):
        self.match_substring_options.reset(
            new CMatchSubstringOptions(tobytes(pattern), ignore_case))


class MatchSubstringOptions(_MatchSubstringOptions):
    def __init__(self, pattern, bint ignore_case=False):
        self._set_options(pattern, ignore_case)


cdef class _TrimOptions(FunctionOptions):
    cdef:
        unique_ptr[CTrimOptions] trim_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.trim_options.get()

    def _set_options(self, characters):
        self.trim_options.reset(
            new CTrimOptions(tobytes(characters)))


class TrimOptions(_TrimOptions):
    def __init__(self, characters):
        self._set_options(characters)


cdef class _ReplaceSubstringOptions(FunctionOptions):
    cdef:
        unique_ptr[CReplaceSubstringOptions] replace_substring_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.replace_substring_options.get()

    def _set_options(self, pattern, replacement, max_replacements):
        self.replace_substring_options.reset(
            new CReplaceSubstringOptions(tobytes(pattern),
                                         tobytes(replacement),
                                         max_replacements)
        )


class ReplaceSubstringOptions(_ReplaceSubstringOptions):
    def __init__(self, pattern, replacement, max_replacements=-1):
        self._set_options(pattern, replacement, max_replacements)


cdef class _ExtractRegexOptions(FunctionOptions):
    cdef:
        unique_ptr[CExtractRegexOptions] extract_regex_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.extract_regex_options.get()

    def _set_options(self, pattern):
        self.extract_regex_options.reset(
            new CExtractRegexOptions(tobytes(pattern)))


class ExtractRegexOptions(_ExtractRegexOptions):
    def __init__(self, pattern):
        self._set_options(pattern)


cdef class _FilterOptions(FunctionOptions):
    cdef:
        unique_ptr[CFilterOptions] filter_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.filter_options.get()

    def _set_options(self, null_selection_behavior):
        if null_selection_behavior == 'drop':
            self.filter_options.reset(
                new CFilterOptions(CFilterNullSelectionBehavior_DROP))
        elif null_selection_behavior == 'emit_null':
            self.filter_options.reset(
                new CFilterOptions(CFilterNullSelectionBehavior_EMIT_NULL))
        else:
            raise ValueError(
                '"{}" is not a valid null_selection_behavior'
                .format(null_selection_behavior))


class FilterOptions(_FilterOptions):
    def __init__(self, null_selection_behavior='drop'):
        self._set_options(null_selection_behavior)


cdef class _DictionaryEncodeOptions(FunctionOptions):
    cdef:
        unique_ptr[CDictionaryEncodeOptions] dictionary_encode_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.dictionary_encode_options.get()

    def _set_options(self, null_encoding_behavior):
        if null_encoding_behavior == 'encode':
            self.dictionary_encode_options.reset(
                new CDictionaryEncodeOptions(
                    CDictionaryEncodeNullEncodingBehavior_ENCODE))
        elif null_encoding_behavior == 'mask':
            self.dictionary_encode_options.reset(
                new CDictionaryEncodeOptions(
                    CDictionaryEncodeNullEncodingBehavior_MASK))
        else:
            raise ValueError('"{}" is not a valid null_encoding_behavior'
                             .format(null_encoding_behavior))


class DictionaryEncodeOptions(_DictionaryEncodeOptions):
    def __init__(self, null_encoding_behavior='mask'):
        self._set_options(null_encoding_behavior)


cdef class _TakeOptions(FunctionOptions):
    cdef:
        unique_ptr[CTakeOptions] take_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.take_options.get()

    def _set_options(self, boundscheck):
        self.take_options.reset(new CTakeOptions(boundscheck))


class TakeOptions(_TakeOptions):
    def __init__(self, *, boundscheck=True):
        self._set_options(boundscheck)


cdef class _PartitionNthOptions(FunctionOptions):
    cdef:
        unique_ptr[CPartitionNthOptions] partition_nth_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.partition_nth_options.get()

    def _set_options(self, int64_t pivot):
        self.partition_nth_options.reset(new CPartitionNthOptions(pivot))


class PartitionNthOptions(_PartitionNthOptions):
    def __init__(self, int64_t pivot):
        self._set_options(pivot)


cdef class _ProjectOptions(FunctionOptions):
    cdef:
        unique_ptr[CProjectOptions] project_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.project_options.get()

    def _set_options(self, field_names):
        cdef:
            vector[c_string] c_field_names
        for n in field_names:
            c_field_names.push_back(tobytes(n))
        self.project_options.reset(new CProjectOptions(field_names))


class ProjectOptions(_ProjectOptions):
    def __init__(self, field_names):
        self._set_options(field_names)


cdef class _ScalarAggregateOptions(FunctionOptions):
    cdef:
        unique_ptr[CScalarAggregateOptions] scalar_aggregate_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.scalar_aggregate_options.get()

    def _set_options(self, skip_nulls, min_count):
        self.scalar_aggregate_options.reset(
            new CScalarAggregateOptions(skip_nulls, min_count))


class ScalarAggregateOptions(_ScalarAggregateOptions):
    def __init__(self, skip_nulls=True, min_count=1):
        self._set_options(skip_nulls, min_count)


cdef class _IndexOptions(FunctionOptions):
    cdef:
        unique_ptr[CIndexOptions] index_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.index_options.get()

    def _set_options(self, Scalar scalar):
        self.index_options.reset(
            new CIndexOptions(pyarrow_unwrap_scalar(scalar)))


class IndexOptions(_IndexOptions):
    """
    Options for the index kernel.

    Parameters
    ----------
    value : Scalar
        The value to search for.
    """

    def __init__(self, value):
        self._set_options(value)


cdef class _ModeOptions(FunctionOptions):
    cdef:
        unique_ptr[CModeOptions] mode_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.mode_options.get()

    def _set_options(self, n):
        self.mode_options.reset(new CModeOptions(n))


class ModeOptions(_ModeOptions):
    def __init__(self, n=1):
        self._set_options(n)


cdef class _SetLookupOptions(FunctionOptions):
    cdef:
        unique_ptr[CSetLookupOptions] set_lookup_options
        unique_ptr[CDatum] valset

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.set_lookup_options.get()

    def _set_options(self, value_set, c_bool skip_nulls):
        if isinstance(value_set, Array):
            self.valset.reset(new CDatum((<Array> value_set).sp_array))
        elif isinstance(value_set, ChunkedArray):
            self.valset.reset(
                new CDatum((<ChunkedArray> value_set).sp_chunked_array)
            )
        elif isinstance(value_set, Scalar):
            self.valset.reset(new CDatum((<Scalar> value_set).unwrap()))
        else:
            raise ValueError('"{}" is not a valid value_set'.format(value_set))

        self.set_lookup_options.reset(
            new CSetLookupOptions(deref(self.valset), skip_nulls)
        )


class SetLookupOptions(_SetLookupOptions):
    def __init__(self, *, value_set, skip_nulls=False):
        self._set_options(value_set, skip_nulls)


cdef class _StrptimeOptions(FunctionOptions):
    cdef:
        unique_ptr[CStrptimeOptions] strptime_options
        TimeUnit time_unit

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.strptime_options.get()

    def _set_options(self, format, unit):
        if unit == 's':
            self.time_unit = TimeUnit_SECOND
        elif unit == 'ms':
            self.time_unit = TimeUnit_MILLI
        elif unit == 'us':
            self.time_unit = TimeUnit_MICRO
        elif unit == 'ns':
            self.time_unit = TimeUnit_NANO
        else:
            raise ValueError('"{}" is not a valid time unit'.format(unit))

        self.strptime_options.reset(
            new CStrptimeOptions(tobytes(format), self.time_unit)
        )


class StrptimeOptions(_StrptimeOptions):
    def __init__(self, format, unit):
        self._set_options(format, unit)


cdef class _VarianceOptions(FunctionOptions):
    cdef:
        unique_ptr[CVarianceOptions] variance_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.variance_options.get()

    def _set_options(self, ddof):
        self.variance_options.reset(new CVarianceOptions(ddof))


class VarianceOptions(_VarianceOptions):
    def __init__(self, *, ddof=0):
        self._set_options(ddof)


cdef class _SplitOptions(FunctionOptions):
    cdef:
        unique_ptr[CSplitOptions] split_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.split_options.get()

    def _set_options(self, max_splits, reverse):
        self.split_options.reset(
            new CSplitOptions(max_splits, reverse))


class SplitOptions(_SplitOptions):
    def __init__(self, *, max_splits=-1, reverse=False):
        self._set_options(max_splits, reverse)


cdef class _SplitPatternOptions(FunctionOptions):
    cdef:
        unique_ptr[CSplitPatternOptions] split_pattern_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.split_pattern_options.get()

    def _set_options(self, pattern, max_splits, reverse):
        self.split_pattern_options.reset(
            new CSplitPatternOptions(tobytes(pattern), max_splits, reverse))


class SplitPatternOptions(_SplitPatternOptions):
    def __init__(self, *, pattern, max_splits=-1, reverse=False):
        self._set_options(pattern, max_splits, reverse)


cdef class _ArraySortOptions(FunctionOptions):
    cdef:
        unique_ptr[CArraySortOptions] array_sort_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.array_sort_options.get()

    def _set_options(self, order):
        if order == "ascending":
            self.array_sort_options.reset(
                new CArraySortOptions(CSortOrder_Ascending))
        elif order == "descending":
            self.array_sort_options.reset(
                new CArraySortOptions(CSortOrder_Descending))
        else:
            raise ValueError(
                "{!r} is not a valid order".format(order)
            )


class ArraySortOptions(_ArraySortOptions):
    def __init__(self, *, order='ascending'):
        self._set_options(order)


cdef class _SortOptions(FunctionOptions):
    cdef:
        unique_ptr[CSortOptions] sort_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.sort_options.get()

    def _set_options(self, sort_keys):
        cdef:
            vector[CSortKey] c_sort_keys
            c_string c_name
            CSortOrder c_order

        for name, order in sort_keys:
            if order == "ascending":
                c_order = CSortOrder_Ascending
            elif order == "descending":
                c_order = CSortOrder_Descending
            else:
                raise ValueError(
                    "{!r} is not a valid order".format(order)
                )
            c_name = tobytes(name)
            c_sort_keys.push_back(CSortKey(c_name, c_order))

        self.sort_options.reset(new CSortOptions(c_sort_keys))


class SortOptions(_SortOptions):
    def __init__(self, sort_keys=None):
        if sort_keys is None:
            sort_keys = []
        self._set_options(sort_keys)


cdef class _QuantileOptions(FunctionOptions):
    cdef:
        unique_ptr[CQuantileOptions] quantile_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.quantile_options.get()

    def _set_options(self, quantiles, interp):
        interp_dict = {
            'linear': CQuantileInterp_LINEAR,
            'lower': CQuantileInterp_LOWER,
            'higher': CQuantileInterp_HIGHER,
            'nearest': CQuantileInterp_NEAREST,
            'midpoint': CQuantileInterp_MIDPOINT,
        }
        if interp not in interp_dict:
            raise ValueError(
                '{!r} is not a valid interpolation'
                .format(interp))
        self.quantile_options.reset(
            new CQuantileOptions(quantiles, interp_dict[interp]))


class QuantileOptions(_QuantileOptions):
    def __init__(self, *, q=0.5, interpolation='linear'):
        if not isinstance(q, (list, tuple, np.ndarray)):
            q = [q]
        self._set_options(q, interpolation)


cdef class _TDigestOptions(FunctionOptions):
    cdef:
        unique_ptr[CTDigestOptions] tdigest_options

    cdef const CFunctionOptions* get_options(self) except NULL:
        return self.tdigest_options.get()

    def _set_options(self, quantiles, delta, buffer_size):
        self.tdigest_options.reset(
            new CTDigestOptions(quantiles, delta, buffer_size))


class TDigestOptions(_TDigestOptions):
    def __init__(self, *, q=0.5, delta=100, buffer_size=500):
        if not isinstance(q, (list, tuple, np.ndarray)):
            q = [q]
        self._set_options(q, delta, buffer_size)
