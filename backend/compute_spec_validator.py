"""Static validation for the JSON App Compute VM v2 contract.

The Dart compiler remains the execution authority. This module mirrors its
public schema closely enough to reject malformed or resource-abusive programs
before they are published.
"""

from __future__ import annotations

import base64
import binascii
import math
import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


ErrorCallback = Callable[[str, str], None]

MAX_FUNCTIONS = 2048
MAX_BUFFERS = 256
MAX_U8_BYTES = 16 * 1024 * 1024
MAX_I32_WORDS = 4 * 1024 * 1024
MAX_BUFFER_BYTES = 16 * 1024 * 1024
MAX_INITIALIZER_ELEMENTS = 256 * 1024
MAX_AST_NODES = 500_000
MAX_AST_DEPTH = 128
MAX_NAME_LENGTH = 128
MAX_INSTRUCTIONS = 500_000
MAX_REGISTERS_PER_FUNCTION = 8_192
MAX_CONSTANTS = 65_536
MAX_CALL_SITES = 65_536
MAX_SWITCH_SITES = 8_192
MAX_BULK_SITES = 8_192
MAX_SWITCH_TABLE_ENTRIES = 65_536
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_ACTION_BUDGET = 25_000_000
MAX_TRANSFER_ELEMENTS = 1024 * 1024
MAX_BASE64_CHARACTERS = ((MAX_TRANSFER_ELEMENTS + 2) // 3) * 4

_BINARY_OPS = {
    "+",
    "*",
    "/",
    "%",
    "&",
    "|",
    "^",
    "<<",
    ">>",
    "==",
    "!=",
    "<",
    "<=",
    ">",
    ">=",
    "min",
    "max",
    "and",
    "or",
}
_UNARY_OPS = {"~", "not"}


@dataclass(frozen=True)
class _ResourceUsage:
    instructions: int
    temporaries: int
    call_sites: int = 0
    switch_sites: int = 0
    bulk_sites: int = 0


def validate_compute_config(root: dict[str, Any], error: ErrorCallback) -> None:
    raw_compute = root.get("compute")
    if raw_compute is None:
        return
    if root.get("dsl") != "4.0":
        error("$.dsl", "compute requires the DSL 4.0 client contract")
    if not isinstance(raw_compute, dict):
        error("$.compute", "compute must be an object")
        return

    engine = raw_compute.get("engine")
    if not isinstance(engine, dict):
        error("$.compute.engine", "compute.engine must be an object")
    else:
        if engine.get("abi") != 2:
            error("$.compute.engine.abi", "compute engine abi must be 2")
        if engine.get("backend") != "vm":
            error("$.compute.engine.backend", "compute backend must be 'vm'")
        if engine.get("semantics") != "i32-v2":
            error(
                "$.compute.engine.semantics",
                "compute semantics must be 'i32-v2'",
            )
        default_budget = engine.get("defaultBudget", 500_000)
        max_budget = engine.get("maxBudget", MAX_ACTION_BUDGET)
        if not _is_positive_integer(default_budget):
            error(
                "$.compute.engine.defaultBudget",
                "defaultBudget must be a positive integer",
            )
        if not _is_positive_integer(max_budget):
            error(
                "$.compute.engine.maxBudget",
                "maxBudget must be a positive integer",
            )
        elif max_budget > MAX_ACTION_BUDGET:
            error(
                "$.compute.engine.maxBudget",
                f"maxBudget exceeds the client ceiling {MAX_ACTION_BUDGET}",
            )
        if (
            _is_positive_integer(default_budget)
            and _is_positive_integer(max_budget)
            and default_budget > max_budget
        ):
            error(
                "$.compute.engine.defaultBudget",
                "defaultBudget must not exceed maxBudget",
            )

    program = raw_compute.get("program")
    if not isinstance(program, dict):
        error("$.compute.program", "compute.program must be an object")
        return
    _ProgramValidator(program, error).validate()


def validate_compute_action(
    root: dict[str, Any],
    call: str,
    args: dict[str, Any],
    path: str,
    error: ErrorCallback,
) -> None:
    """Validate one public ``@compute.*`` action against its module."""

    args_path = _path(path, "args")
    supported = {
        "@compute.call",
        "@compute.load",
        "@compute.read",
        "@compute.reset",
        "@compute.write",
    }
    if call not in supported:
        error(_path(path, "call"), f"unknown compute action: {call}")
        return

    compute = root.get("compute") if isinstance(root, dict) else None
    if not isinstance(compute, dict):
        error(path, f"{call} requires a top-level compute module")
        program = None
    else:
        raw_program = compute.get("program")
        program = raw_program if isinstance(raw_program, dict) else None

    if call == "@compute.call":
        function = args.get("function")
        if function is None:
            function = args.get("name")
        dynamic_function = _has_action_template(function)
        if not isinstance(function, str) or not function:
            error(
                _path(args_path, "function"),
                "@compute.call requires a function name",
            )
        functions = program.get("functions") if program is not None else None
        declaration = None
        if (
            isinstance(function, str)
            and function
            and not dynamic_function
            and isinstance(functions, dict)
        ):
            declaration = functions.get(function)
            if function not in functions:
                error(
                    _path(args_path, "function"),
                    f"unknown compute function: {function}",
                )
        values = args.get("args")
        if values is None:
            values = []
        dynamic_values = _is_action_value_template(values)
        if not isinstance(values, list) and not dynamic_values:
            error(
                _path(args_path, "args"),
                "@compute.call args must be a list or interpolation",
            )
        elif isinstance(values, list):
            if len(values) > MAX_REGISTERS_PER_FUNCTION:
                error(
                    _path(args_path, "args"),
                    "@compute.call args exceed "
                    f"{MAX_REGISTERS_PER_FUNCTION} elements",
                )
            else:
                for index, value in enumerate(values):
                    _validate_action_integer(
                        value,
                        f"{_path(args_path, 'args')}[{index}]",
                        "compute argument",
                        error,
                    )
            if isinstance(declaration, dict):
                parameters = declaration.get("params", [])
                if isinstance(parameters, list) and len(values) != len(parameters):
                    error(
                        _path(args_path, "args"),
                        f"compute function {function!r} expects "
                        f"{len(parameters)} args, got {len(values)}",
                    )
        if "budget" in args:
            budget_path = _path(args_path, "budget")
            budget = _validate_action_integer(
                args["budget"],
                budget_path,
                "@compute.call budget",
                error,
                minimum=1,
                maximum=MAX_ACTION_BUDGET,
            )
            if budget is not None and isinstance(compute, dict):
                engine = compute.get("engine")
                engine_max = (
                    engine.get("maxBudget", MAX_ACTION_BUDGET)
                    if isinstance(engine, dict)
                    else MAX_ACTION_BUDGET
                )
                if (
                    _is_safe_integer(engine_max)
                    and engine_max > 0
                    and budget > int(engine_max)
                ):
                    error(
                        budget_path,
                        f"@compute.call budget exceeds engine maxBudget "
                        f"{int(engine_max)}",
                    )
        return

    if call == "@compute.reset":
        return

    raw_kind = args.get("kind")
    if call == "@compute.load" and raw_kind is None:
        kind: str | None = "u8"
    elif _has_action_template(raw_kind):
        kind = None
    elif isinstance(raw_kind, str) and raw_kind in {"u8", "i32"}:
        kind = raw_kind
    else:
        allowed = "'u8'" if call == "@compute.load" else "'u8' or 'i32'"
        error(
            _path(args_path, "kind"),
            f"{call} kind must be {allowed}",
        )
        kind = None
    if call == "@compute.load" and kind == "i32":
        error(
            _path(args_path, "kind"),
            "@compute.load kind must be 'u8'",
        )
        kind = None

    raw_buffer = args.get("buffer")
    if not isinstance(raw_buffer, str) or not raw_buffer:
        error(
            _path(args_path, "buffer"),
            f"{call} requires a buffer name",
        )
        buffer_name = None
    elif _has_action_template(raw_buffer):
        buffer_name = None
    else:
        buffer_name = raw_buffer

    buffer_size = None
    if program is not None and kind is not None and buffer_name is not None:
        declarations = program.get(
            "buffers" if kind == "u8" else "i32",
            {},
        )
        if isinstance(declarations, dict):
            if buffer_name not in declarations:
                error(
                    _path(args_path, "buffer"),
                    f"unknown {kind} compute buffer: {buffer_name}",
                )
            else:
                raw_size = declarations[buffer_name]
                if _is_non_negative_integer(raw_size):
                    buffer_size = int(raw_size)

    raw_offset = args.get("offset")
    if raw_offset is None:
        raw_offset = args.get("index", 0)
    offset = _validate_action_integer(
        raw_offset,
        _path(args_path, "offset"),
        f"{call} offset",
        error,
        minimum=0,
    )

    if call == "@compute.read":
        if "length" in args:
            length = _validate_action_integer(
                args["length"],
                _path(args_path, "length"),
                "@compute.read length",
                error,
                minimum=0,
                maximum=MAX_TRANSFER_ELEMENTS,
            )
        else:
            length = 1
        _validate_action_range(
            offset,
            length,
            buffer_size,
            args_path,
            operation="read",
            error=error,
        )
        return

    if call == "@compute.write":
        length = None
        if "values" in args:
            values = args["values"]
            if _is_action_value_template(values):
                pass
            elif not isinstance(values, list):
                error(
                    _path(args_path, "values"),
                    "@compute.write values must be a list or interpolation",
                )
            else:
                length = len(values)
                if length > MAX_TRANSFER_ELEMENTS:
                    error(
                        _path(args_path, "values"),
                        "@compute.write values exceed "
                        f"{MAX_TRANSFER_ELEMENTS} elements",
                    )
                else:
                    for index, value in enumerate(values):
                        _validate_action_integer(
                            value,
                            f"{_path(args_path, 'values')}[{index}]",
                            "compute write value",
                            error,
                        )
        elif "value" in args:
            _validate_action_integer(
                args["value"],
                _path(args_path, "value"),
                "compute write value",
                error,
            )
            length = 1
        else:
            error(args_path, "@compute.write requires value or values")
        _validate_action_range(
            offset,
            length,
            buffer_size,
            args_path,
            operation="write",
            error=error,
        )
        return

    encoded = args.get("base64")
    if encoded is None:
        encoded = args.get("data")
    if not isinstance(encoded, str) or not encoded:
        error(args_path, "@compute.load requires non-empty base64 data")
        decoded_length = None
    elif _has_action_template(encoded):
        decoded_length = None
    elif _dart_string_length(encoded) > MAX_BASE64_CHARACTERS:
        error(
            args_path,
            "@compute.load encoded data exceeds the transfer limit",
        )
        decoded_length = None
    else:
        try:
            decoded_length = _decoded_base64_length(encoded)
        except (binascii.Error, UnicodeEncodeError, ValueError):
            error(args_path, "@compute.load data must be valid base64")
            decoded_length = None
        if (
            decoded_length is not None
            and decoded_length > MAX_TRANSFER_ELEMENTS
        ):
            error(
                args_path,
                "@compute.load data exceed "
                f"{MAX_TRANSFER_ELEMENTS} decoded bytes",
            )
            decoded_length = None
    _validate_action_range(
        offset,
        decoded_length,
        buffer_size,
        args_path,
        operation="load",
        error=error,
    )


class _ProgramValidator:
    def __init__(self, program: dict[str, Any], error: ErrorCallback) -> None:
        self.program = program
        self.error = error
        self.u8: dict[str, int] = {}
        self.i32: dict[str, int] = {}
        self.signatures: dict[str, list[str]] = {}
        self.ast_nodes = 0
        self.instructions = 0
        self.instruction_limit_reported = False
        self.constants: set[int] = set()
        self.constant_limit_reported = False
        self.call_sites = 0
        self.call_site_limit_reported = False
        self.switch_sites = 0
        self.switch_site_limit_reported = False
        self.bulk_sites = 0
        self.bulk_site_limit_reported = False
        self.switch_table_entries = 0

    def validate(self) -> None:
        version = self.program.get("version")
        if not _is_integer(version) or version != 2:
            self.error(
                "$.compute.program.version",
                "compute program version must be the numeric value 2",
            )

        self.u8 = self._buffers(
            "buffers",
            MAX_U8_BYTES,
            "bytes",
        )
        self.i32 = self._buffers(
            "i32",
            MAX_I32_WORDS,
            "words",
        )
        total_buffer_bytes = sum(self.u8.values()) + (
            sum(self.i32.values()) * 4
        )
        if total_buffer_bytes > MAX_BUFFER_BYTES:
            self.error(
                "$.compute.program",
                "typed buffers exceed "
                f"{MAX_BUFFER_BYTES} total bytes",
            )
        if len(self.u8) + len(self.i32) > MAX_BUFFERS:
            self.error(
                "$.compute.program",
                f"compute program exceeds {MAX_BUFFERS} typed buffers",
            )
        for name in self.u8.keys() & self.i32.keys():
            self.error(
                f"$.compute.program.i32.{name}",
                "u8 and i32 buffers must not share a name",
            )

        self._initializers()
        functions = self.program.get("functions")
        if not isinstance(functions, dict):
            self.error(
                "$.compute.program.functions",
                "functions must be an object",
            )
            return
        if len(functions) > MAX_FUNCTIONS:
            self.error(
                "$.compute.program.functions",
                f"program exceeds {MAX_FUNCTIONS} functions",
            )

        bodies: dict[str, list[Any]] = {}
        for function_index, (raw_name, declaration) in enumerate(
            functions.items()
        ):
            if function_index >= MAX_FUNCTIONS:
                break
            path = f"$.compute.program.functions.{raw_name}"
            name = self._name(raw_name, path)
            if name is None:
                continue
            if not isinstance(declaration, dict):
                self.error(path, "function declaration must be an object")
                continue
            raw_params = declaration.get("params", [])
            raw_body = declaration.get("body", [])
            too_many_parameters = False
            if not isinstance(raw_params, list):
                self.error(f"{path}.params", "params must be a list")
                raw_params = []
            elif len(raw_params) > MAX_REGISTERS_PER_FUNCTION:
                too_many_parameters = True
                self.error(
                    f"{path}.params",
                    "function exceeds "
                    f"{MAX_REGISTERS_PER_FUNCTION} parameters/registers",
                )
                raw_params = raw_params[:MAX_REGISTERS_PER_FUNCTION]
            if not isinstance(raw_body, list):
                self.error(f"{path}.body", "body must be a list")
                raw_body = []
            params: list[str] = []
            seen: set[str] = set()
            for index, raw_param in enumerate(raw_params):
                param = self._name(raw_param, f"{path}.params[{index}]")
                if param is None:
                    continue
                if param in seen:
                    self.error(
                        f"{path}.params[{index}]",
                        f"duplicate parameter {param!r}",
                    )
                else:
                    seen.add(param)
                    params.append(param)
            self.signatures[name] = params
            if not too_many_parameters:
                bodies[name] = raw_body

        for name, body in bodies.items():
            path = f"$.compute.program.functions.{name}.body"
            locals_ = set(self.signatures[name])
            if not self._collect_locals(body, path, locals_):
                continue
            self._validate_block(
                body,
                path,
                locals_,
                loop_depth=0,
                switch_depth=0,
                depth=1,
            )
            usage = self._block_resource_usage(body)
            if usage is None:
                continue
            function_instructions = usage.instructions + 1
            self.instructions += function_instructions
            if (
                self.instructions > MAX_INSTRUCTIONS
                and not self.instruction_limit_reported
            ):
                self.instruction_limit_reported = True
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_INSTRUCTIONS} compiled instructions",
                )
            register_count = len(locals_) + usage.temporaries
            if register_count > MAX_REGISTERS_PER_FUNCTION:
                self.error(
                    path,
                    f"function requires {register_count} registers; "
                    f"client limit is {MAX_REGISTERS_PER_FUNCTION}",
                )
            self.call_sites += usage.call_sites
            if (
                self.call_sites > MAX_CALL_SITES
                and not self.call_site_limit_reported
            ):
                self.call_site_limit_reported = True
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_CALL_SITES} call sites",
                )
            self.switch_sites += usage.switch_sites
            if (
                self.switch_sites > MAX_SWITCH_SITES
                and not self.switch_site_limit_reported
            ):
                self.switch_site_limit_reported = True
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_SWITCH_SITES} switch sites",
                )
            self.bulk_sites += usage.bulk_sites
            if (
                self.bulk_sites > MAX_BULK_SITES
                and not self.bulk_site_limit_reported
            ):
                self.bulk_site_limit_reported = True
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_BULK_SITES} bulk sites",
                )
            if (
                len(self.constants) > MAX_CONSTANTS
                and not self.constant_limit_reported
            ):
                self.constant_limit_reported = True
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_CONSTANTS} unique constants",
                )

    def _buffers(self, key: str, maximum: int, unit: str) -> dict[str, int]:
        path = f"$.compute.program.{key}"
        raw = self.program.get(key, {})
        if not isinstance(raw, dict):
            self.error(path, f"{key} must be an object")
            return {}
        if len(raw) > MAX_BUFFERS:
            self.error(path, f"{key} exceeds {MAX_BUFFERS} entries")
        result: dict[str, int] = {}
        total = 0
        for index, (raw_name, raw_size) in enumerate(raw.items()):
            if index >= MAX_BUFFERS:
                break
            item_path = f"{path}.{raw_name}"
            name = self._name(raw_name, item_path)
            if name is None:
                continue
            if not _is_non_negative_integer(raw_size):
                self.error(item_path, "buffer size must be a non-negative integer")
                continue
            result[name] = raw_size
            total += raw_size
        if total > maximum:
            self.error(path, f"buffers exceed {maximum} total {unit}")
        return result

    def _initializers(self) -> None:
        raw = self.program.get("init", {})
        path = "$.compute.program.init"
        if not isinstance(raw, dict):
            self.error(path, "init must be an object")
            return
        total_elements = 0
        if len(raw) > MAX_BUFFERS:
            self.error(path, f"init exceeds {MAX_BUFFERS} entries")
        for index, (raw_name, values) in enumerate(raw.items()):
            if index >= MAX_BUFFERS:
                break
            item_path = f"{path}.{raw_name}"
            name = self._name(raw_name, item_path)
            if name is None:
                continue
            size = self.u8.get(name)
            if size is None:
                size = self.i32.get(name)
            if size is None:
                self.error(item_path, "initializer names an unknown buffer")
                continue
            if not isinstance(values, list):
                self.error(item_path, "initializer must be a list")
                continue
            total_elements += len(values)
            if total_elements > MAX_INITIALIZER_ELEMENTS:
                self.error(
                    path,
                    "initializers exceed "
                    f"{MAX_INITIALIZER_ELEMENTS} total elements; "
                    "use @compute.load for bulk byte data",
                )
                return
            if len(values) > size:
                self.error(
                    item_path,
                    f"initializer length {len(values)} exceeds buffer length {size}",
                )
                continue
            for index, value in enumerate(values):
                if not _is_safe_integer(value):
                    self.error(
                        f"{item_path}[{index}]",
                        "initializer value must be a safe integer",
                    )

    def _collect_locals(
        self,
        body: list[Any],
        path: str,
        locals_: set[str],
    ) -> bool:
        stack: list[tuple[Any, str, int]] = [(body, path, 1)]
        while stack:
            node, node_path, depth = stack.pop()
            self.ast_nodes += 1
            if self.ast_nodes > MAX_AST_NODES:
                self.error(
                    "$.compute.program.functions",
                    f"program exceeds {MAX_AST_NODES} AST nodes",
                )
                return False
            if depth > MAX_AST_DEPTH:
                self.error(node_path, f"AST nesting exceeds {MAX_AST_DEPTH}")
                return False
            if not isinstance(node, list):
                continue
            if (
                len(node) >= 2
                and node[0] == "set"
                and isinstance(node[1], str)
                and node[1]
                and _dart_string_length(node[1]) <= MAX_NAME_LENGTH
            ):
                if (
                    node[1] not in locals_
                    and len(locals_) >= MAX_REGISTERS_PER_FUNCTION
                ):
                    self.error(
                        node_path,
                        "function exceeds "
                        f"{MAX_REGISTERS_PER_FUNCTION} locals/registers",
                    )
                    return False
                locals_.add(node[1])
            for index in range(len(node) - 1, -1, -1):
                stack.append((node[index], f"{node_path}[{index}]", depth + 1))
        return True

    def _validate_block(
        self,
        block: Any,
        path: str,
        locals_: set[str],
        *,
        loop_depth: int,
        switch_depth: int,
        depth: int,
    ) -> None:
        if depth > MAX_AST_DEPTH:
            self.error(path, f"AST nesting exceeds {MAX_AST_DEPTH}")
            return
        if not isinstance(block, list):
            self.error(path, "expected a statement list")
            return
        for index, statement in enumerate(block):
            self._validate_statement(
                statement,
                f"{path}[{index}]",
                locals_,
                loop_depth=loop_depth,
                switch_depth=switch_depth,
                depth=depth + 1,
            )

    def _validate_statement(
        self,
        node: Any,
        path: str,
        locals_: set[str],
        *,
        loop_depth: int,
        switch_depth: int,
        depth: int,
    ) -> None:
        if not isinstance(node, list) or not node or not isinstance(node[0], str):
            self.error(path, "statement must be a non-empty opcode list")
            return
        op = node[0]
        if op == "set":
            if not self._length(node, 3, path):
                return
            name = self._name(node[1], f"{path}[1]")
            if name is not None and name not in locals_:
                self.error(f"{path}[1]", f"unknown local {name!r}")
            self._validate_expression(node[2], f"{path}[2]", locals_, depth + 1)
        elif op in {"setu8", "seti32"}:
            if not self._length(node, 4, path):
                return
            self._buffer_reference(op, node[1], f"{path}[1]")
            self._validate_expression(node[2], f"{path}[2]", locals_, depth + 1)
            self._validate_expression(node[3], f"{path}[3]", locals_, depth + 1)
        elif op == "memset":
            if not self._length(node, 5, path):
                return
            self._buffer_reference(op, node[1], f"{path}[1]")
            for index in range(2, 5):
                self._validate_expression(
                    node[index],
                    f"{path}[{index}]",
                    locals_,
                    depth + 1,
                )
        elif op == "memlut":
            if not self._length(node, 8, path):
                return
            for index in (1, 3, 6):
                self._buffer_reference(op, node[index], f"{path}[{index}]")
            for index in (2, 4, 5, 7):
                self._validate_expression(
                    node[index],
                    f"{path}[{index}]",
                    locals_,
                    depth + 1,
                )
        elif op == "planar8":
            if not self._length(node, 7, path):
                return
            self._buffer_reference(op, node[1], f"{path}[1]")
            for index in range(2, 7):
                self._validate_expression(
                    node[index],
                    f"{path}[{index}]",
                    locals_,
                    depth + 1,
                )
        elif op == "if":
            if len(node) not in {3, 4}:
                self.error(path, "if expects condition, then, and optional else")
                return
            self._validate_expression(node[1], f"{path}[1]", locals_, depth + 1)
            self._validate_block(
                node[2],
                f"{path}[2]",
                locals_,
                loop_depth=loop_depth,
                switch_depth=switch_depth,
                depth=depth + 1,
            )
            if len(node) == 4 and node[3] is not None:
                self._validate_block(
                    node[3],
                    f"{path}[3]",
                    locals_,
                    loop_depth=loop_depth,
                    switch_depth=switch_depth,
                    depth=depth + 1,
                )
        elif op in {"while", "repeat"}:
            if not self._length(node, 3, path):
                return
            self._validate_expression(node[1], f"{path}[1]", locals_, depth + 1)
            self._validate_block(
                node[2],
                f"{path}[2]",
                locals_,
                loop_depth=loop_depth + 1,
                switch_depth=switch_depth,
                depth=depth + 1,
            )
        elif op == "switch":
            self._validate_switch(
                node,
                path,
                locals_,
                loop_depth=loop_depth,
                switch_depth=switch_depth,
                depth=depth,
            )
        elif op == "block":
            if self._length(node, 2, path):
                self._validate_block(
                    node[1],
                    f"{path}[1]",
                    locals_,
                    loop_depth=loop_depth,
                    switch_depth=switch_depth,
                    depth=depth + 1,
                )
        elif op in {"call", "host"}:
            self._validate_expression(node, path, locals_, depth + 1)
        elif op == "ret":
            if len(node) not in {1, 2}:
                self.error(path, "ret expects zero or one expression")
            elif len(node) == 2 and node[1] is not None:
                self._validate_expression(node[1], f"{path}[1]", locals_, depth + 1)
        elif op == "break":
            if not self._length(node, 1, path):
                return
            if loop_depth == 0 and switch_depth == 0:
                self.error(path, "break is only valid inside a loop or switch")
        elif op == "continue":
            if not self._length(node, 1, path):
                return
            if loop_depth == 0:
                self.error(path, "continue is only valid inside a loop")
        elif op == "nop":
            self._length(node, 1, path)
        else:
            self.error(f"{path}[0]", f"unknown statement opcode {op!r}")

    def _validate_switch(
        self,
        node: list[Any],
        path: str,
        locals_: set[str],
        *,
        loop_depth: int,
        switch_depth: int,
        depth: int,
    ) -> None:
        if len(node) not in {3, 4}:
            self.error(path, "switch expects selector, cases, and optional default")
            return
        self._validate_expression(node[1], f"{path}[1]", locals_, depth + 1)
        cases = node[2]
        if not isinstance(cases, list):
            self.error(f"{path}[2]", "switch cases must be a list")
            return
        seen: set[int] = set()
        for index, entry in enumerate(cases):
            entry_path = f"{path}[2][{index}]"
            if not isinstance(entry, list) or len(entry) != 2:
                self.error(entry_path, "switch case must be [integer, statements]")
                continue
            if not _is_safe_integer(entry[0]):
                self.error(f"{entry_path}[0]", "switch case must be a safe integer")
            else:
                normalized = _int32(int(entry[0]))
                if normalized in seen:
                    self.error(
                        f"{entry_path}[0]",
                        f"duplicate normalized switch case {normalized}",
                    )
                seen.add(normalized)
            self._validate_block(
                entry[1],
                f"{entry_path}[1]",
                locals_,
                loop_depth=loop_depth,
                switch_depth=switch_depth + 1,
                depth=depth + 1,
            )
        sorted_keys = sorted(seen)
        if sorted_keys:
            span = sorted_keys[-1] - sorted_keys[0] + 1
            site_entries = (
                span
                if span <= 65_536 and span <= len(sorted_keys) * 2
                else len(sorted_keys) * 2
            )
            self.switch_table_entries += site_entries
            if self.switch_table_entries > MAX_SWITCH_TABLE_ENTRIES:
                self.error(
                    f"{path}[2]",
                    "program exceeds "
                    f"{MAX_SWITCH_TABLE_ENTRIES} switch table entries",
                )
        if len(node) == 4 and node[3] is not None:
            self._validate_block(
                node[3],
                f"{path}[3]",
                locals_,
                loop_depth=loop_depth,
                switch_depth=switch_depth + 1,
                depth=depth + 1,
            )

    def _validate_expression(
        self,
        node: Any,
        path: str,
        locals_: set[str],
        depth: int,
    ) -> None:
        if depth > MAX_AST_DEPTH:
            self.error(path, f"AST nesting exceeds {MAX_AST_DEPTH}")
            return
        if isinstance(node, bool):
            return
        if _is_safe_integer(node):
            return
        if not isinstance(node, list) or not node or not isinstance(node[0], str):
            self.error(path, "expression must be an integer or opcode list")
            return
        op = node[0]
        if op == "var":
            if not self._length(node, 2, path):
                return
            name = self._name(node[1], f"{path}[1]")
            if name is not None and name not in locals_:
                self.error(f"{path}[1]", f"unknown local {name!r}")
        elif op == "lit":
            if self._length(node, 2, path) and not _is_safe_integer(node[1]):
                self.error(f"{path}[1]", "literal must be a safe integer")
        elif op in {"u8", "i32"}:
            if not self._length(node, 3, path):
                return
            self._buffer_reference(op, node[1], f"{path}[1]")
            self._validate_expression(node[2], f"{path}[2]", locals_, depth + 1)
        elif op == "call":
            if len(node) not in {2, 3}:
                self.error(path, "call expects a function and optional args list")
                return
            name = self._name(node[1], f"{path}[1]")
            args = node[2] if len(node) == 3 else []
            if not isinstance(args, list):
                self.error(f"{path}[2]", "call arguments must be a list")
                return
            expected = self.signatures.get(name) if name is not None else None
            if expected is None and name is not None:
                self.error(f"{path}[1]", f"call to unknown function {name!r}")
            elif expected is not None and len(args) != len(expected):
                self.error(
                    path,
                    f"function {name!r} expects {len(expected)} args, got {len(args)}",
                )
            for index, value in enumerate(args):
                self._validate_expression(
                    value,
                    f"{path}[2][{index}]",
                    locals_,
                    depth + 1,
                )
        elif op == "host":
            self.error(
                path,
                "host functions are unavailable to JSON App compute modules",
            )
        elif op == "-":
            if len(node) not in {2, 3}:
                self.error(path, "- expects one or two operands")
                return
            for index in range(1, len(node)):
                self._validate_expression(
                    node[index],
                    f"{path}[{index}]",
                    locals_,
                    depth + 1,
                )
        elif op in _BINARY_OPS:
            if not self._length(node, 3, path):
                return
            self._validate_expression(node[1], f"{path}[1]", locals_, depth + 1)
            self._validate_expression(node[2], f"{path}[2]", locals_, depth + 1)
        elif op in _UNARY_OPS:
            if self._length(node, 2, path):
                self._validate_expression(
                    node[1],
                    f"{path}[1]",
                    locals_,
                    depth + 1,
                )
        elif op == "?:":
            if not self._length(node, 4, path):
                return
            for index in range(1, 4):
                self._validate_expression(
                    node[index],
                    f"{path}[{index}]",
                    locals_,
                    depth + 1,
                )
        else:
            self.error(f"{path}[0]", f"unknown expression opcode {op!r}")

    def _block_resource_usage(self, block: Any) -> _ResourceUsage | None:
        if not isinstance(block, list):
            return None
        instructions = 0
        temporaries = 0
        call_sites = 0
        switch_sites = 0
        bulk_sites = 0
        for statement in block:
            usage = self._statement_resource_usage(statement)
            if usage is None:
                return None
            instructions += usage.instructions
            temporaries = max(temporaries, usage.temporaries)
            call_sites += usage.call_sites
            switch_sites += usage.switch_sites
            bulk_sites += usage.bulk_sites
        return _ResourceUsage(
            instructions,
            temporaries,
            call_sites,
            switch_sites,
            bulk_sites,
        )

    def _statement_resource_usage(self, node: Any) -> _ResourceUsage | None:
        if not isinstance(node, list) or not node or not isinstance(node[0], str):
            return None
        op = node[0]
        if op == "set" and len(node) == 3:
            value = self._expression_resource_usage(node[2])
            return self._with_instructions(value, 1)
        if op in {"setu8", "seti32"} and len(node) == 4:
            return self._expression_sequence_usage(
                [node[2], node[3]],
                extra_instructions=1,
            )
        if op == "memset" and len(node) == 5:
            usage = self._expression_sequence_usage(
                [node[2], node[3], node[4]],
                extra_instructions=1,
            )
            return self._with_bulk_site(usage)
        if op == "memlut" and len(node) == 8:
            usage = self._expression_sequence_usage(
                [node[2], node[4], node[5], node[7]],
                extra_instructions=1,
            )
            return self._with_bulk_site(usage)
        if op == "planar8" and len(node) == 7:
            usage = self._expression_sequence_usage(
                [node[2], node[3], node[4], node[5], node[6]],
                extra_instructions=1,
            )
            return self._with_bulk_site(usage)
        if op == "if" and len(node) in {3, 4}:
            condition = self._expression_resource_usage(node[1])
            when_true = self._block_resource_usage(node[2])
            if condition is None or when_true is None:
                return None
            instructions = condition.instructions + 1 + when_true.instructions
            temporaries = max(
                condition.temporaries,
                when_true.temporaries,
            )
            call_sites = condition.call_sites + when_true.call_sites
            switch_sites = condition.switch_sites + when_true.switch_sites
            bulk_sites = condition.bulk_sites + when_true.bulk_sites
            if len(node) == 4 and node[3] is not None:
                when_false = self._block_resource_usage(node[3])
                if when_false is None:
                    return None
                instructions += 1 + when_false.instructions
                temporaries = max(temporaries, when_false.temporaries)
                call_sites += when_false.call_sites
                switch_sites += when_false.switch_sites
                bulk_sites += when_false.bulk_sites
            return _ResourceUsage(
                instructions,
                temporaries,
                call_sites,
                switch_sites,
                bulk_sites,
            )
        if op == "while" and len(node) == 3:
            condition = self._expression_resource_usage(node[1])
            body = self._block_resource_usage(node[2])
            if condition is None or body is None:
                return None
            return _ResourceUsage(
                condition.instructions + body.instructions + 2,
                max(condition.temporaries, body.temporaries),
                condition.call_sites + body.call_sites,
                condition.switch_sites + body.switch_sites,
                condition.bulk_sites + body.bulk_sites,
            )
        if op == "repeat" and len(node) == 3:
            count = self._expression_resource_usage(node[1])
            body = self._block_resource_usage(node[2])
            if count is None or body is None:
                return None
            return _ResourceUsage(
                count.instructions + body.instructions + 4,
                max(count.temporaries, 1 + body.temporaries),
                count.call_sites + body.call_sites,
                count.switch_sites + body.switch_sites,
                count.bulk_sites + body.bulk_sites,
            )
        if op == "switch" and len(node) in {3, 4}:
            selector = self._expression_resource_usage(node[1])
            cases = node[2]
            if selector is None or not isinstance(cases, list):
                return None
            instructions = selector.instructions + 1
            temporaries = selector.temporaries
            call_sites = selector.call_sites
            switch_sites = selector.switch_sites + 1
            bulk_sites = selector.bulk_sites
            for entry in cases:
                if not isinstance(entry, list) or len(entry) != 2:
                    return None
                body = self._block_resource_usage(entry[1])
                if body is None:
                    return None
                instructions += body.instructions + 1
                temporaries = max(temporaries, 1 + body.temporaries)
                call_sites += body.call_sites
                switch_sites += body.switch_sites
                bulk_sites += body.bulk_sites
            if len(node) == 4 and node[3] is not None:
                default = self._block_resource_usage(node[3])
                if default is None:
                    return None
                instructions += default.instructions
                temporaries = max(temporaries, 1 + default.temporaries)
                call_sites += default.call_sites
                switch_sites += default.switch_sites
                bulk_sites += default.bulk_sites
            return _ResourceUsage(
                instructions,
                temporaries,
                call_sites,
                switch_sites,
                bulk_sites,
            )
        if op in {"call", "host"}:
            return self._expression_resource_usage(node)
        if op == "ret" and len(node) in {1, 2}:
            if len(node) == 1 or node[1] is None:
                return _ResourceUsage(1, 0)
            value = self._expression_resource_usage(node[1])
            return self._with_instructions(value, 1)
        if op in {"break", "continue"} and len(node) == 1:
            return _ResourceUsage(1, 0)
        if op == "block" and len(node) == 2:
            return self._block_resource_usage(node[1])
        if op == "nop" and len(node) == 1:
            return _ResourceUsage(0, 0)
        return None

    def _expression_resource_usage(self, node: Any) -> _ResourceUsage | None:
        if isinstance(node, bool):
            self.constants.add(1 if node else 0)
            return _ResourceUsage(1, 1)
        if _is_safe_integer(node):
            self.constants.add(_int32(int(node)))
            return _ResourceUsage(1, 1)
        if not isinstance(node, list) or not node or not isinstance(node[0], str):
            return None
        op = node[0]
        if op == "var" and len(node) == 2:
            return _ResourceUsage(1, 1)
        if op == "lit" and len(node) == 2:
            if _is_safe_integer(node[1]):
                self.constants.add(_int32(int(node[1])))
            return _ResourceUsage(1, 1)
        if op in {"u8", "i32"} and len(node) == 3:
            index = self._expression_resource_usage(node[2])
            return self._with_instructions(index, 1)
        if op in {"call", "host"} and len(node) in {2, 3}:
            arguments = node[2] if len(node) == 3 else []
            if not isinstance(arguments, list):
                return None
            usage = self._expression_sequence_usage(arguments)
            if usage is None:
                return None
            return _ResourceUsage(
                usage.instructions + 1,
                max(usage.temporaries, 1),
                usage.call_sites + (1 if op == "call" else 0),
                usage.switch_sites,
                usage.bulk_sites,
            )
        if op == "-":
            if len(node) == 2:
                value = self._expression_resource_usage(node[1])
                return self._with_instructions(value, 1)
            if len(node) == 3:
                return self._expression_sequence_usage(
                    [node[1], node[2]],
                    extra_instructions=1,
                )
            return None
        if op in {"and", "or"} and len(node) == 3:
            self.constants.add(0 if op == "and" else 1)
            return self._expression_sequence_usage(
                [node[1], node[2]],
                extra_instructions=6,
            )
        if op in _BINARY_OPS and len(node) == 3:
            return self._expression_sequence_usage(
                [node[1], node[2]],
                extra_instructions=1,
            )
        if op in _UNARY_OPS and len(node) == 2:
            value = self._expression_resource_usage(node[1])
            return self._with_instructions(value, 1)
        if op == "?:" and len(node) == 4:
            condition = self._expression_resource_usage(node[1])
            when_true = self._expression_resource_usage(node[2])
            when_false = self._expression_resource_usage(node[3])
            if condition is None or when_true is None or when_false is None:
                return None
            return _ResourceUsage(
                condition.instructions
                + when_true.instructions
                + when_false.instructions
                + 4,
                max(
                    condition.temporaries,
                    1 + when_true.temporaries,
                    1 + when_false.temporaries,
                ),
                condition.call_sites
                + when_true.call_sites
                + when_false.call_sites,
                condition.switch_sites
                + when_true.switch_sites
                + when_false.switch_sites,
                condition.bulk_sites
                + when_true.bulk_sites
                + when_false.bulk_sites,
            )
        return None

    def _expression_sequence_usage(
        self,
        expressions: list[Any],
        *,
        extra_instructions: int = 0,
    ) -> _ResourceUsage | None:
        instructions = extra_instructions
        temporaries = 0
        call_sites = 0
        switch_sites = 0
        bulk_sites = 0
        live = 0
        for expression in expressions:
            usage = self._expression_resource_usage(expression)
            if usage is None:
                return None
            instructions += usage.instructions
            temporaries = max(temporaries, live + usage.temporaries)
            call_sites += usage.call_sites
            switch_sites += usage.switch_sites
            bulk_sites += usage.bulk_sites
            live += 1
        return _ResourceUsage(
            instructions,
            temporaries,
            call_sites,
            switch_sites,
            bulk_sites,
        )

    @staticmethod
    def _with_instructions(
        usage: _ResourceUsage | None,
        count: int,
    ) -> _ResourceUsage | None:
        if usage is None:
            return None
        return _ResourceUsage(
            usage.instructions + count,
            usage.temporaries,
            usage.call_sites,
            usage.switch_sites,
            usage.bulk_sites,
        )

    @staticmethod
    def _with_bulk_site(
        usage: _ResourceUsage | None,
    ) -> _ResourceUsage | None:
        if usage is None:
            return None
        return _ResourceUsage(
            usage.instructions,
            usage.temporaries,
            usage.call_sites,
            usage.switch_sites,
            usage.bulk_sites + 1,
        )

    def _buffer_reference(self, op: str, value: Any, path: str) -> None:
        name = self._name(value, path)
        if name is None:
            return
        buffers = (
            self.u8
            if op in {"u8", "setu8", "memset", "memlut", "planar8"}
            else self.i32
        )
        if name not in buffers:
            self.error(path, f"unknown {'u8' if buffers is self.u8 else 'i32'} buffer {name!r}")

    def _name(self, value: Any, path: str) -> str | None:
        if not isinstance(value, str) or not value:
            self.error(path, "name must be a non-empty string")
            return None
        if _dart_string_length(value) > MAX_NAME_LENGTH:
            self.error(
                path,
                f"name exceeds {MAX_NAME_LENGTH} UTF-16 code units",
            )
            return None
        return value

    def _length(self, node: list[Any], expected: int, path: str) -> bool:
        if len(node) != expected:
            self.error(
                path,
                f"expected {expected - 1} operands, got {len(node) - 1}",
            )
            return False
        return True


def _is_integer(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value) and value.is_integer()


def _is_safe_integer(value: Any) -> bool:
    return _is_integer(value) and abs(value) <= MAX_SAFE_INTEGER


def _is_positive_integer(value: Any) -> bool:
    return _is_safe_integer(value) and value > 0


def _is_non_negative_integer(value: Any) -> bool:
    return _is_safe_integer(value) and value >= 0


def _has_action_template(value: Any) -> bool:
    return isinstance(value, str) and "{{" in value and "}}" in value


def _is_action_value_template(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    match = re.fullmatch(r"\{\{([^{}]+)\}\}", value)
    return match is not None and bool(match.group(1).strip())


def _decoded_base64_length(value: str) -> int:
    characters = bytearray()
    index = 0
    while index < len(value):
        character = value[index]
        if character != "%":
            code = ord(character)
            if code > 127:
                raise ValueError("base64 data must be ASCII")
            characters.append(code)
            index += 1
            continue
        if index + 2 >= len(value):
            raise ValueError("incomplete percent escape")
        escaped = value[index + 1 : index + 3]
        try:
            code = int(escaped, 16)
        except ValueError as error:
            raise ValueError("invalid percent escape") from error
        characters.append(code)
        index += 3

    normalized = characters.decode("ascii").translate(str.maketrans("-_", "+/"))
    first_padding = normalized.find("=")
    if first_padding >= 0:
        padding_count = len(normalized) - first_padding
        if (
            len(normalized) % 4 != 0
            or padding_count > 2
            or normalized[first_padding:] != "=" * padding_count
        ):
            raise ValueError("invalid base64 padding")
        padded = normalized
    else:
        remainder = len(normalized) % 4
        if remainder == 1:
            raise ValueError("invalid base64 length")
        padded = normalized + ("=" * ((-len(normalized)) % 4))

    unpadded = normalized.rstrip("=")
    estimated_length = len(unpadded) * 6 // 8
    if estimated_length > MAX_TRANSFER_ELEMENTS:
        return estimated_length
    decoded = base64.b64decode(padded, validate=True)
    return len(decoded)


def _validate_action_integer(
    value: Any,
    path: str,
    label: str,
    error: ErrorCallback,
    *,
    minimum: int = -MAX_SAFE_INTEGER,
    maximum: int = MAX_SAFE_INTEGER,
) -> int | None:
    if _is_action_value_template(value):
        return None
    if not _is_safe_integer(value) or value < minimum or value > maximum:
        if minimum == maximum:
            expectation = str(minimum)
        elif minimum == -MAX_SAFE_INTEGER and maximum == MAX_SAFE_INTEGER:
            expectation = "a cross-platform safe integer"
        else:
            expectation = f"an integer in {minimum}..{maximum}"
        error(path, f"{label} must be {expectation} or interpolation")
        return None
    return int(value)


def _validate_action_range(
    offset: int | None,
    length: int | None,
    buffer_size: int | None,
    path: str,
    *,
    operation: str,
    error: ErrorCallback,
) -> None:
    if offset is None or length is None or buffer_size is None:
        return
    if offset > buffer_size or length > buffer_size - offset:
        error(
            path,
            f"compute.{operation} range [{offset}, {offset + length}) "
            f"exceeds buffer length {buffer_size}",
        )


def _path(base: str, key: str) -> str:
    return f"{base}.{key}"


def _dart_string_length(value: str) -> int:
    return len(value.encode("utf-16-le", errors="surrogatepass")) // 2


def _int32(value: int) -> int:
    return ((value + (1 << 31)) % (1 << 32)) - (1 << 31)
