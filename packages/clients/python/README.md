# Python client (пример)

```bash
pip install grpcio grpcio-tools
python -m grpc_tools.protoc \
    -I../../proto \
    --python_out=. \
    --grpc_python_out=. \
    unison.proto

python hello.py 1
```

`unison.proto` лежит в `packages/proto/unison.proto`. Генерация даёт
`unison_pb2.py` и `unison_pb2_grpc.py` в текущей папке — `hello.py` их импортит.
