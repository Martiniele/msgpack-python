# coding: utf-8
#cython: embedsignature=True

from cpython cimport *
cdef extern from "Python.h":
    ctypedef char* const_char_ptr "const char*"
    ctypedef char* const_void_ptr "const void*"
    ctypedef struct PyObject
    cdef int PyObject_AsReadBuffer(object o, const_void_ptr* buff, Py_ssize_t* buf_len) except -1

from libc.stdlib cimport *
from libc.string cimport *
from libc.limits cimport *

from msgpack.exceptions import (
        BufferFull,
        OutOfData,
        UnpackValueError,
        ExtraData,
        )



cdef extern from "unpack.h":
    ctypedef struct msgpack_user:
        bint use_list
        PyObject* object_hook
        bint has_pairs_hook # call object_hook with k-v pairs
        PyObject* list_hook
        char *encoding
        char *unicode_errors

    ctypedef struct template_context:
        msgpack_user user
        PyObject* obj
        size_t count
        unsigned int ct
        PyObject* key

    ctypedef int (*execute_fn)(template_context* ctx, const_char_ptr data,
                               size_t len, size_t* off) except? -1
    execute_fn template_construct
    execute_fn template_skip
    execute_fn read_array_header
    execute_fn read_map_header
    void template_init(template_context* ctx)
    object template_data(template_context* ctx)

cdef inline init_ctx(template_context *ctx,
                     object object_hook, object object_pairs_hook, object list_hook,
                     bint use_list, char* encoding, char* unicode_errors):
    template_init(ctx)
    ctx.user.use_list = use_list
    ctx.user.object_hook = ctx.user.list_hook = <PyObject*>NULL

    if object_hook is not None and object_pairs_hook is not None:
        raise ValueError("object_pairs_hook and object_hook are mutually exclusive.")

    if object_hook is not None:
        if not PyCallable_Check(object_hook):
            raise TypeError("object_hook must be a callable.")
        ctx.user.object_hook = <PyObject*>object_hook

    if object_pairs_hook is None:
        ctx.user.has_pairs_hook = False
    else:
        if not PyCallable_Check(object_pairs_hook):
            raise TypeError("object_pairs_hook must be a callable.")
        ctx.user.object_hook = <PyObject*>object_pairs_hook
        ctx.user.has_pairs_hook = True

    if list_hook is not None:
        if not PyCallable_Check(list_hook):
            raise TypeError("list_hook must be a callable.")
        ctx.user.list_hook = <PyObject*>list_hook

    ctx.user.encoding = encoding
    ctx.user.unicode_errors = unicode_errors

def unpackb(object packed, object object_hook=None, object list_hook=None,
            bint use_list=1, encoding=None, unicode_errors="strict",
            object_pairs_hook=None,
            ):
    """Unpack packed_bytes to object. Returns an unpacked object.

    Raises `ValueError` when `packed` contains extra bytes.
    """
    cdef template_context ctx
    cdef size_t off = 0
    cdef int ret

    cdef char* buf
    cdef Py_ssize_t buf_len
    cdef char* cenc = NULL
    cdef char* cerr = NULL

    PyObject_AsReadBuffer(packed, <const_void_ptr*>&buf, &buf_len)

    if encoding is not None:
        if isinstance(encoding, unicode):
            encoding = encoding.encode('ascii')
        cenc = PyBytes_AsString(encoding)

    if unicode_errors is not None:
        if isinstance(unicode_errors, unicode):
            unicode_errors = unicode_errors.encode('ascii')
        cerr = PyBytes_AsString(unicode_errors)

    init_ctx(&ctx, object_hook, object_pairs_hook, list_hook, use_list, cenc, cerr)
    ret = template_construct(&ctx, buf, buf_len, &off)
    if ret == 1:
        obj = template_data(&ctx)
        if off < buf_len:
            raise ExtraData(obj, PyBytes_FromStringAndSize(buf+off, buf_len-off))
        return obj
    else:
        raise UnpackValueError("Unpack failed: error = %d" % (ret,))


def unpack(object stream, object object_hook=None, object list_hook=None,
           bint use_list=1, encoding=None, unicode_errors="strict",
           object_pairs_hook=None,
           ):
    """Unpack an object from `stream`.

    Raises `ValueError` when `stream` has extra bytes.
    """
    return unpackb(stream.read(), use_list=use_list,
                   object_hook=object_hook, object_pairs_hook=object_pairs_hook, list_hook=list_hook,
                   encoding=encoding, unicode_errors=unicode_errors,
                   )


cdef class Unpacker(object):
    """
    Streaming unpacker.

    `file_like` is a file-like object having `.read(n)` method.
    When `Unpacker` initialized with `file_like`, unpacker reads serialized data
    from it and `.feed()` method is not usable.

    `read_size` is used as `file_like.read(read_size)`.
    (default: min(1024**2, max_buffer_size))

    If `use_list` is true (default), msgpack list is deserialized to Python list.
    Otherwise, it is deserialized to Python tuple.

    `object_hook` is same to simplejson. If it is not None, it should be callable
    and Unpacker calls it with a dict argument after deserializing a map.

    `object_pairs_hook` is same to simplejson. If it is not None, it should be callable
    and Unpacker calls it with a list of key-value pairs after deserializing a map.

    `encoding` is encoding used for decoding msgpack bytes. If it is None (default),
    msgpack bytes is deserialized to Python bytes.

    `unicode_errors` is used for decoding bytes.

    `max_buffer_size` limits size of data waiting unpacked.
    0 means system's INT_MAX (default).
    Raises `BufferFull` exception when it is insufficient.
    You shoud set this parameter when unpacking data from untrasted source.

    example of streaming deserialize from file-like object::

        unpacker = Unpacker(file_like)
        for o in unpacker:
            do_something(o)

    example of streaming deserialize from socket::

        unpacker = Unpacker()
        while 1:
            buf = sock.recv(1024**2)
            if not buf:
                break
            unpacker.feed(buf)
            for o in unpacker:
                do_something(o)
    """
    cdef template_context ctx
    cdef char* buf
    cdef size_t buf_size, buf_head, buf_tail
    cdef object file_like
    cdef object file_like_read
    cdef Py_ssize_t read_size
    cdef object object_hook
    cdef object encoding, unicode_errors
    cdef size_t max_buffer_size

    def __cinit__(self):
        self.buf = NULL

    def __dealloc__(self):
        free(self.buf)
        self.buf = NULL

    def __init__(self, file_like=None, Py_ssize_t read_size=0, bint use_list=1,
                 object object_hook=None, object object_pairs_hook=None, object list_hook=None,
                 encoding=None, unicode_errors='strict', int max_buffer_size=0,
                 ):
        cdef char *cenc=NULL, *cerr=NULL

        self.file_like = file_like
        if file_like:
            self.file_like_read = file_like.read
            if not PyCallable_Check(self.file_like_read):
                raise ValueError("`file_like.read` must be a callable.")
        if not max_buffer_size:
            max_buffer_size = INT_MAX
        if read_size > max_buffer_size:
            raise ValueError("read_size should be less or equal to max_buffer_size")
        if not read_size:
            read_size = min(max_buffer_size, 1024**2)
        self.max_buffer_size = max_buffer_size
        self.read_size = read_size
        self.buf = <char*>malloc(read_size)
        if self.buf == NULL:
            raise MemoryError("Unable to allocate internal buffer.")
        self.buf_size = read_size
        self.buf_head = 0
        self.buf_tail = 0

        if encoding is not None:
            if isinstance(encoding, unicode):
                encoding = encoding.encode('ascii')
            self.encoding = encoding
            cenc = PyBytes_AsString(encoding)

        if unicode_errors is not None:
            if isinstance(unicode_errors, unicode):
                unicode_errors = unicode_errors.encode('ascii')
            self.unicode_errors = unicode_errors
            cerr = PyBytes_AsString(unicode_errors)

        init_ctx(&self.ctx, object_hook, object_pairs_hook, list_hook, use_list, cenc, cerr)

    def feed(self, object next_bytes):
        """Append `next_bytes` to internal buffer."""
        cdef char* buf
        cdef Py_ssize_t buf_len
        if self.file_like is not None:
            raise AssertionError(
                    "unpacker.feed() is not be able to use with `file_like`.")
        PyObject_AsReadBuffer(next_bytes, <const_void_ptr*>&buf, &buf_len)
        self.append_buffer(buf, buf_len)

    cdef append_buffer(self, void* _buf, Py_ssize_t _buf_len):
        cdef:
            char* buf = self.buf
            char* new_buf
            size_t head = self.buf_head
            size_t tail = self.buf_tail
            size_t buf_size = self.buf_size
            size_t new_size

        if tail + _buf_len > buf_size:
            if ((tail - head) + _buf_len) <= buf_size:
                # move to front.
                memmove(buf, buf + head, tail - head)
                tail -= head
                head = 0
            else:
                # expand buffer.
                new_size = (tail-head) + _buf_len
                if new_size > self.max_buffer_size:
                    raise BufferFull
                new_size = min(new_size*2, self.max_buffer_size)
                new_buf = <char*>malloc(new_size)
                if new_buf == NULL:
                    # self.buf still holds old buffer and will be freed during
                    # obj destruction
                    raise MemoryError("Unable to enlarge internal buffer.")
                memcpy(new_buf, buf + head, tail - head)
                free(buf)

                buf = new_buf
                buf_size = new_size
                tail -= head
                head = 0

        memcpy(buf + tail, <char*>(_buf), _buf_len)
        self.buf = buf
        self.buf_head = head
        self.buf_size = buf_size
        self.buf_tail = tail + _buf_len

    cdef read_from_file(self):
        next_bytes = self.file_like_read(
                min(self.read_size,
                    self.max_buffer_size - (self.buf_tail - self.buf_head)
                    ))
        if next_bytes:
            self.append_buffer(PyBytes_AsString(next_bytes), PyBytes_Size(next_bytes))
        else:
            self.file_like = None

    cdef object _unpack(self, execute_fn execute, object write_bytes, bint iter=0):
        cdef int ret
        cdef object obj
        cdef size_t prev_head
        while 1:
            prev_head = self.buf_head
            ret = execute(&self.ctx, self.buf, self.buf_tail, &self.buf_head)
            if write_bytes is not None:
                write_bytes(PyBytes_FromStringAndSize(self.buf + prev_head, self.buf_head - prev_head))

            if ret == 1:
                obj = template_data(&self.ctx)
                template_init(&self.ctx)
                return obj
            elif ret == 0:
                if self.file_like is not None:
                    self.read_from_file()
                    continue
                if iter:
                    raise StopIteration("No more data to unpack.")
                else:
                    raise OutOfData("No more data to unpack.")
            else:
                raise ValueError("Unpack failed: error = %d" % (ret,))

    def read_bytes(self, Py_ssize_t nbytes):
        """read a specified number of raw bytes from the stream"""
        cdef size_t nread
        nread = min(self.buf_tail - self.buf_head, nbytes)
        ret = PyBytes_FromStringAndSize(self.buf + self.buf_head, nread)
        self.buf_head += nread
        if len(ret) < nbytes and self.file_like is not None:
            ret += self.file_like.read(nbytes - len(ret))
        return ret

    def unpack(self, object write_bytes=None):
        """
        unpack one object

        If write_bytes is not None, it will be called with parts of the raw
        message as it is unpacked.

        Raises `OutOfData` when there are no more bytes to unpack.
        """
        return self._unpack(template_construct, write_bytes)

    def skip(self, object write_bytes=None):
        """
        read and ignore one object, returning None

        If write_bytes is not None, it will be called with parts of the raw
        message as it is unpacked.

        Raises `OutOfData` when there are no more bytes to unpack.
        """
        return self._unpack(template_skip, write_bytes)

    def read_array_header(self, object write_bytes=None):
        """assuming the next object is an array, return its size n, such that
        the next n unpack() calls will iterate over its contents.

        Raises `OutOfData` when there are no more bytes to unpack.
        """
        return self._unpack(read_array_header, write_bytes)

    def read_map_header(self, object write_bytes=None):
        """assuming the next object is a map, return its size n, such that the
        next n * 2 unpack() calls will iterate over its key-value pairs.

        Raises `OutOfData` when there are no more bytes to unpack.
        """
        return self._unpack(read_map_header, write_bytes)

    def __iter__(self):
        return self

    def __next__(self):
        return self._unpack(template_construct, None, 1)

    # for debug.
    #def _buf(self):
    #    return PyString_FromStringAndSize(self.buf, self.buf_tail)

    #def _off(self):
    #    return self.buf_head
