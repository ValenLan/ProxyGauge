cmake_minimum_required(VERSION 3.24)

project(ProxyGaugeGuard LANGUAGES CXX)

add_executable(ProxyGauge.Guard Guard.cpp)
target_compile_features(ProxyGauge.Guard PRIVATE cxx_std_20)
target_compile_definitions(ProxyGauge.Guard PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(ProxyGauge.Guard PRIVATE /W4 /WX /permissive- /utf-8)
target_link_libraries(ProxyGauge.Guard PRIVATE advapi32 fwpuclnt iphlpapi ws2_32)

install(TARGETS ProxyGauge.Guard RUNTIME DESTINATION .)
