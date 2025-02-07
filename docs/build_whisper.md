
TBD


build .a static lib, move lib and headers to project. Include c++ std and other libs to the project linking.

```curl
cd ../.. && rm -rf build && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_CXX_STANDARD=11 -DCMAKE_CXX_FLAGS="-fvisibility=hidden" -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF ..

make -j$(sysctl -n hw.ncpu)
```
