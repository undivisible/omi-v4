# SLF4J API is pulled transitively; Android has no binding. Ignore the
# optional static binder so R8 can minify release builds.
-dontwarn org.slf4j.impl.StaticLoggerBinder
