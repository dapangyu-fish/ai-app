from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import compute_spec_validator as C  # noqa: E402
import validate_json_app as V  # noqa: E402


def _app() -> dict:
    return {
        "dsl": "4.0",
        "meta": {"name": "compute-test", "version": "1.0.0", "type": "app"},
        "global": {"variables": {}, "functions": {}},
        "compute": {
            "engine": {
                "abi": 2,
                "backend": "vm",
                "semantics": "i32-v2",
                "defaultBudget": 100_000,
                "maxBudget": 200_000,
            },
            "program": {
                "version": 2,
                "buffers": {"bytes": 8},
                "i32": {"words": 4},
                "init": {"bytes": [1, 2], "words": [3]},
                "functions": {
                    "sum": {
                        "params": ["n"],
                        "body": [
                            ["set", "i", 0],
                            ["set", "total", 0],
                            [
                                "while",
                                ["<", ["var", "i"], ["var", "n"]],
                                [
                                    [
                                        "set",
                                        "total",
                                        ["+", ["var", "total"], ["var", "i"]],
                                    ],
                                    ["set", "i", ["+", ["var", "i"], 1]],
                                ],
                            ],
                            [
                                "switch",
                                ["var", "total"],
                                [
                                    [0, [["setu8", "bytes", 0, 9]]],
                                    [1, [["seti32", "words", 0, 10]]],
                                ],
                                [["nop"]],
                            ],
                            ["ret", ["var", "total"]],
                        ],
                    }
                },
            },
        },
        "steps": [
            {
                "call": "@compute.call",
                "args": {"function": "sum", "args": [10]},
                "assign": "global.result",
            }
        ],
        "ui": {
            "screens": [
                {"id": "home", "title": "Compute", "children": []},
            ]
        },
    }


def _findings(app: dict) -> list[V.Finding]:
    validator = V.Validator(app, V.load_builtin_calls())
    validator.validate()
    return validator.findings


def _errors(app: dict) -> list[V.Finding]:
    return [finding for finding in _findings(app) if finding.level == "ERROR"]


def test_valid_compute_contract_passes() -> None:
    assert _errors(_app()) == []


def test_compute_budget_ceiling_accepts_25m_and_rejects_more() -> None:
    app = _app()
    app["compute"]["engine"]["defaultBudget"] = C.MAX_ACTION_BUDGET
    app["compute"]["engine"]["maxBudget"] = C.MAX_ACTION_BUDGET
    app["steps"][0]["args"]["budget"] = C.MAX_ACTION_BUDGET
    assert _errors(app) == []

    app["compute"]["engine"]["defaultBudget"] = C.MAX_ACTION_BUDGET + 1
    app["compute"]["engine"]["maxBudget"] = C.MAX_ACTION_BUDGET + 1
    messages = " | ".join(f.message for f in _errors(app))
    assert f"client ceiling {C.MAX_ACTION_BUDGET}" in messages


def test_valid_generic_bulk_statements_pass() -> None:
    app = _app()
    app["steps"] = []
    program = app["compute"]["program"]
    program["buffers"].update({"source": 8, "lookup": 256})
    program["functions"]["sum"]["body"] = [
        ["memset", "bytes", 0, ["var", "n"], 7],
        ["memlut", "bytes", 0, "source", 0, 8, "lookup", 0],
        ["planar8", "bytes", 0, 0x91, 0x50, 12, 0],
        ["ret", 0],
    ]

    assert _errors(app) == []
    assert C.MAX_ACTION_BUDGET == 25_000_000


def test_bulk_statements_reject_bad_shapes_and_non_u8_buffers() -> None:
    app = _app()
    app["steps"] = []
    app["compute"]["program"]["functions"]["sum"]["body"] = [
        ["memset", "words", 0, 1, 2],
        ["memlut", "bytes", 0, "missing", 0, 1, "words", 0],
        ["planar8", "bytes", 0, 0, 0, 0],
    ]

    messages = " | ".join(f.message for f in _errors(app))
    assert "unknown u8 buffer 'words'" in messages
    assert "unknown u8 buffer 'missing'" in messages
    assert "expected 6 operands, got 5" in messages


def test_planar8_requires_a_u8_destination_buffer() -> None:
    app = _app()
    app["steps"] = []
    app["compute"]["program"]["functions"]["sum"]["body"] = [
        ["planar8", "words", 0, 0, 0, 0, 0],
    ]

    assert any(
        finding.path.endswith(".body[0][1]")
        and finding.message == "unknown u8 buffer 'words'"
        for finding in _errors(app)
    )


def test_compute_program_version_accepts_numeric_two_only() -> None:
    app = _app()
    app["compute"]["program"]["version"] = 2.0
    assert _errors(app) == []

    for invalid in (2.5, "2", True):
        app = _app()
        app["compute"]["program"]["version"] = invalid
        messages = " | ".join(f.message for f in _errors(app))
        assert "program version must be the numeric value 2" in messages


def test_compute_requires_dsl4_and_exact_engine_contract() -> None:
    app = _app()
    app["dsl"] = "3.3"
    app["compute"]["engine"] = {
        "abi": 3,
        "backend": "native",
        "semantics": "float",
        "defaultBudget": 300,
        "maxBudget": 200,
    }
    messages = " | ".join(f.message for f in _errors(app))
    assert "DSL 4.0" in messages
    assert "abi must be 2" in messages
    assert "backend must be 'vm'" in messages
    assert "semantics must be 'i32-v2'" in messages
    assert "defaultBudget must not exceed maxBudget" in messages


def test_rejects_ambiguous_buffers_and_invalid_initializers() -> None:
    app = _app()
    program = app["compute"]["program"]
    program["i32"]["bytes"] = 1
    program["init"]["bytes"] = list(range(9))
    program["init"]["missing"] = [1]
    messages = " | ".join(f.message for f in _errors(app))
    assert "must not share a name" in messages
    assert "initializer length 9 exceeds buffer length 8" in messages
    assert "unknown buffer" in messages


def test_rejects_unknown_locals_hosts_and_normalized_duplicate_cases() -> None:
    app = _app()
    app["compute"]["program"]["functions"]["sum"]["body"] = [
        [
            "switch",
            ["var", "typo"],
            [
                [0, [["host", "unsafe"]]],
                [1 << 32, [["nop"]]],
            ],
        ],
        ["ret", 0],
    ]
    messages = " | ".join(f.message for f in _errors(app))
    assert "unknown local 'typo'" in messages
    assert "host functions are unavailable" in messages
    assert "duplicate normalized switch case 0" in messages


def test_compute_ast_is_not_walked_as_ui_or_dependency_data() -> None:
    app = _app()
    app["compute"]["program"]["debugMetadata"] = {
        "type": "not-a-widget",
        "call": "@not_a_dependency.fake",
    }
    messages = " | ".join(f.message for f in _errors(app))
    assert "not_a_dependency" not in messages
    assert "unknown widget" not in messages


def test_valid_compute_actions_and_interpolations_pass() -> None:
    app = _app()
    app["steps"] = [
        {
            "call": "@compute.call",
            "args": {"function": None, "name": "sum", "args": [0]},
        },
        {
            "call": "@compute.call",
            "args": {
                "function": "{{ global.functionName }}",
                "args": "{{ global.functionArgs }}",
                "budget": "{{ global.computeBudget }}",
            },
        },
        {
            "call": "@compute.read",
            "args": {"kind": "u8", "buffer": "bytes", "offset": 0, "length": 2},
        },
        {
            "call": "@compute.write",
            "args": {
                "kind": "i32",
                "buffer": "words",
                "values": [1, "{{ global.result }}"],
            },
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "base64": "AQI="},
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "offset": 2, "base64": "_w"},
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "offset": 3, "base64": "%5Fw"},
        },
        {"call": "@compute.reset", "args": {}},
    ]
    assert _errors(app) == []


def test_compute_call_action_rejects_static_signature_and_budget_errors() -> None:
    app = _app()
    app["steps"] = [
        {
            "call": "@compute.call",
            "args": {"function": "sum", "args": [], "budget": 200_001},
        },
        {
            "call": "@compute.call",
            "args": {"function": "missing", "args": []},
        },
        {
            "call": "@compute.call",
            "args": {"function": "sum", "args": ["not-an-integer"]},
        },
        {
            "call": "@compute.call",
            "args": {"function": "sum", "args": [10**1000]},
        },
        {
            "call": "@compute.call",
            "args": {"function": "sum", "args": ["x{{ global.n }}"]},
        },
        {
            "call": "@compute.call",
            "args": {"function": "sum", "args": [" {{ global.n }} "]},
        },
    ]
    messages = " | ".join(f.message for f in _errors(app))
    assert "expects 1 args, got 0" in messages
    assert "exceeds engine maxBudget 200000" in messages
    assert "unknown compute function: missing" in messages
    assert (
        messages.count(
            "compute argument must be a cross-platform safe integer"
        )
        == 4
    )


def test_compute_buffer_actions_reject_invalid_shapes_and_static_ranges() -> None:
    app = _app()
    app["steps"] = [
        {
            "call": "@compute.read",
            "args": {
                "kind": "i32",
                "buffer": "words",
                "offset": 4,
            },
        },
        {
            "call": "@compute.read",
            "args": {"kind": "i32", "buffer": "bytes"},
        },
        {
            "call": "@compute.write",
            "args": {"kind": "u8", "buffer": "bytes", "values": "plain-text"},
        },
        {
            "call": "@compute.write",
            "args": {
                "kind": "u8",
                "buffer": "bytes",
                "offset": 7,
                "values": [1, 2],
            },
        },
        {
            "call": "@compute.load",
            "args": {"kind": "i32", "buffer": "words"},
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "base64": "!!!"},
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "base64": "AA="},
        },
        {
            "call": "@compute.load",
            "args": {"buffer": "bytes", "offset": 7, "base64": "AQI="},
        },
        {
            "call": "@compute.read",
            "args": {
                "kind": "u8",
                "buffer": "missing",
                "length": 1024 * 1024 + 1,
            },
        },
    ]
    messages = " | ".join(f.message for f in _errors(app))
    assert "compute.read range [4, 5) exceeds buffer length 4" in messages
    assert "unknown i32 compute buffer: bytes" in messages
    assert "@compute.write values must be a list or interpolation" in messages
    assert "compute.write range [7, 9) exceeds buffer length 8" in messages
    assert "@compute.load kind must be 'u8'" in messages
    assert "@compute.load requires non-empty base64 data" in messages
    assert messages.count("@compute.load data must be valid base64") == 2
    assert "compute.load range [7, 9) exceeds buffer length 8" in messages
    assert "unknown u8 compute buffer: missing" in messages
    assert "@compute.read length must be an integer in 0..1048576" in messages


def test_compute_actions_require_module_and_reject_unknown_namespace_calls() -> None:
    app = _app()
    app.pop("compute")
    app["steps"] = [
        {
            "call": "@compute.read",
            "args": {"kind": "u8", "buffer": "bytes"},
        }
    ]
    messages = " | ".join(f.message for f in _errors(app))
    assert "@compute.read requires a top-level compute module" in messages

    app = _app()
    app["steps"] = [{"call": "@compute.typo", "args": {}}]
    messages = " | ".join(f.message for f in _errors(app))
    assert "unknown compute action: @compute.typo" in messages
    assert "requires top-level dependencies.compute" not in messages


def test_dsl3_compute_dependency_namespace_remains_compatible() -> None:
    app = _app()
    app["dsl"] = "3.3"
    app.pop("compute")
    app["dependencies"] = {"compute": "^1.0.0"}
    app["steps"] = [{"call": "@compute.read", "args": {}}]
    messages = " | ".join(f.message for f in _errors(app))
    assert "requires a top-level compute module" not in messages
    assert "requires top-level dependencies.compute" not in messages


def test_compute_program_rejects_parameter_register_overflow() -> None:
    app = _app()
    app["steps"] = []
    app["compute"]["program"]["functions"]["sum"]["params"] = [
        f"p{index}" for index in range(8_193)
    ]
    messages = " | ".join(f.message for f in _errors(app))
    assert "exceeds 8192 parameters/registers" in messages


def test_compute_program_accounts_for_compiled_instructions_and_temporaries() -> None:
    original_instructions = C.MAX_INSTRUCTIONS
    original_registers = C.MAX_REGISTERS_PER_FUNCTION
    try:
        C.MAX_INSTRUCTIONS = 4
        app = _app()
        app["steps"] = []
        app["compute"]["program"]["functions"]["sum"]["body"] = [
            ["ret", ["+", 1, 2]],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "exceeds 4 compiled instructions" in messages

        C.MAX_INSTRUCTIONS = original_instructions
        C.MAX_REGISTERS_PER_FUNCTION = 3
        app = _app()
        app["steps"] = []
        function = app["compute"]["program"]["functions"]["sum"]
        function["params"] = ["a", "b"]
        function["body"] = [
            ["ret", ["+", ["var", "a"], ["var", "b"]]],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "requires 4 registers; client limit is 3" in messages
    finally:
        C.MAX_INSTRUCTIONS = original_instructions
        C.MAX_REGISTERS_PER_FUNCTION = original_registers


def test_compute_load_enforces_decoded_transfer_limit() -> None:
    original = C.MAX_TRANSFER_ELEMENTS
    original_encoded = C.MAX_BASE64_CHARACTERS
    try:
        C.MAX_TRANSFER_ELEMENTS = 1
        app = _app()
        app["steps"] = [
            {
                "call": "@compute.load",
                "args": {"buffer": "bytes", "base64": "AQI="},
            }
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "@compute.load data exceed 1 decoded bytes" in messages

        C.MAX_TRANSFER_ELEMENTS = original
        C.MAX_BASE64_CHARACTERS = 4
        app["steps"][0]["args"]["base64"] = "%41%41"
        messages = " | ".join(f.message for f in _errors(app))
        assert (
            "@compute.load encoded data exceeds the transfer limit"
            in messages
        )
    finally:
        C.MAX_TRANSFER_ELEMENTS = original
        C.MAX_BASE64_CHARACTERS = original_encoded


def test_compute_names_count_utf16_code_units_like_dart() -> None:
    app = _app()
    app["steps"] = []
    app["compute"]["program"]["functions"]["😀" * 64] = {
        "params": [],
        "body": [],
    }
    assert _errors(app) == []

    app["compute"]["program"]["functions"]["😀" * 65] = {
        "params": [],
        "body": [],
    }
    messages = " | ".join(f.message for f in _errors(app))
    assert "name exceeds 128 UTF-16 code units" in messages


def test_deep_compute_ast_returns_finding_instead_of_recursing() -> None:
    statement: list = ["ret", 0]
    for _ in range(1100):
        statement = ["block", [statement]]
    app = _app()
    app["steps"] = []
    app["compute"]["program"]["functions"]["sum"]["body"] = [statement]
    messages = " | ".join(f.message for f in _errors(app))
    assert "AST nesting exceeds 128" in messages


def test_compute_program_enforces_combined_typed_buffer_bytes() -> None:
    original = C.MAX_BUFFER_BYTES
    try:
        C.MAX_BUFFER_BYTES = 7
        app = _app()
        app["steps"] = []
        app["compute"]["program"]["buffers"] = {"bytes": 4}
        app["compute"]["program"]["i32"] = {"words": 1}
        messages = " | ".join(f.message for f in _errors(app))
        assert "typed buffers exceed 7 total bytes" in messages
    finally:
        C.MAX_BUFFER_BYTES = original


def test_compute_program_caps_json_initializer_elements() -> None:
    original = C.MAX_INITIALIZER_ELEMENTS
    try:
        C.MAX_INITIALIZER_ELEMENTS = 1
        app = _app()
        app["steps"] = []
        messages = " | ".join(f.message for f in _errors(app))
        assert "initializers exceed 1 total elements" in messages
    finally:
        C.MAX_INITIALIZER_ELEMENTS = original


def test_compute_program_enforces_side_table_limits() -> None:
    original_calls = C.MAX_CALL_SITES
    original_switches = C.MAX_SWITCH_SITES
    original_bulk = C.MAX_BULK_SITES
    original_constants = C.MAX_CONSTANTS
    try:
        C.MAX_CALL_SITES = 1
        app = _app()
        app["steps"] = []
        functions = app["compute"]["program"]["functions"]
        functions["zero"] = {"params": [], "body": [["ret", 0]]}
        functions["sum"]["body"] = [
            ["call", "zero"],
            ["call", "zero"],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "exceeds 1 call sites" in messages

        C.MAX_CALL_SITES = original_calls
        C.MAX_SWITCH_SITES = 1
        app = _app()
        app["steps"] = []
        app["compute"]["program"]["functions"]["sum"]["body"] = [
            ["switch", 0, []],
            ["switch", 0, []],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "exceeds 1 switch sites" in messages

        C.MAX_SWITCH_SITES = original_switches
        C.MAX_BULK_SITES = 1
        app = _app()
        app["steps"] = []
        app["compute"]["program"]["functions"]["sum"]["body"] = [
            [
                "if",
                1,
                [
                    ["memset", "bytes", 0, 1, 1],
                    ["planar8", "bytes", 0, 0, 0, 0, 0],
                ],
            ],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "exceeds 1 bulk sites" in messages

        C.MAX_BULK_SITES = original_bulk
        C.MAX_CONSTANTS = 1
        app = _app()
        app["steps"] = []
        app["compute"]["program"]["functions"]["sum"]["body"] = [
            ["ret", ["+", 1, 2]],
        ]
        messages = " | ".join(f.message for f in _errors(app))
        assert "exceeds 1 unique constants" in messages
    finally:
        C.MAX_CALL_SITES = original_calls
        C.MAX_SWITCH_SITES = original_switches
        C.MAX_BULK_SITES = original_bulk
        C.MAX_CONSTANTS = original_constants
