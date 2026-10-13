#!/usr/bin/env python3
"""Regenerate tiny custom-model contract fixtures with .venv-models/bin/python."""
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

OUT = Path(__file__).resolve().parents[2] / "FindMyCrewTests/Fixtures/Contracts"
OUT.mkdir(parents=True, exist_ok=True)


def model(name, *, count=32, shape=None, flexible=False, value=1.0, metadata=None,
          extra=False, width=112, height=112):
    builder = NeuralNetworkBuilder(
        [("image", datatypes.Array(3, height, width))]
        + ([("required", datatypes.Array(1))] if extra else []),
        [("embedding", datatypes.Array(count))],
    )
    builder.add_pooling("average", height=height, width=width, stride_height=1, stride_width=1,
                        layer_type="AVERAGE", padding_type="VALID", input_name="image", output_name="average")
    builder.add_inner_product("constant", W=np.zeros((count, 3), dtype=np.float32),
                              b=np.full(count, value, dtype=np.float32), input_channels=3, output_channels=count,
                              has_bias=True, input_name="average", output_name="base" if extra else "embedding")
    if extra:
        builder.add_elementwise("use_required", ["base", "required"], "embedding", mode="ADD")
    builder.set_pre_processing_parameters(image_input_names=["image"])
    spec = builder.spec
    if flexible:
        spec.description.output[0].type.multiArrayType.ClearField("shape")
    elif shape is not None:
        spec.description.output[0].type.multiArrayType.shape[:] = shape
    spec.description.metadata.userDefined.update(metadata or {})
    ct.models.MLModel(spec, skip_model_load=True).save(str(OUT / f"{name}.mlmodel"))


model("ValidVector")
model("ValidBatch", shape=[1, 32])
model("ValidSpatial", shape=[1, 32, 1, 1])
model("Flexible", flexible=True)
model("TooSmall", count=16)
model("Nonfinite", value=float("nan"))
model("ExtraRequired", extra=True)
model("NonSquare", width=112, height=96)
model("TooLarge", width=600, height=600)
model("BadAlignment", metadata={"fmc.alignment": "other"})
for name, threshold in [("NegativeThreshold", "-1"), ("HighThreshold", "1"),
                        ("BadThreshold", "1.01"), ("NaNThreshold", "nan"),
                        ("TextThreshold", "strict")]:
    model(name, metadata={"fmc.defaultThreshold": threshold})
