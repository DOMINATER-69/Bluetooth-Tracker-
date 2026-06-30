#include <jni.h>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <mutex>
#include <android/log.h>

#define LOG_TAG "BtTracker"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── Constants ─────────────────────────────────────────────────────────────────

static constexpr double   EARTH_RADIUS_M  = 6371000.0;
static constexpr double   DEG_TO_RAD      = M_PI / 180.0;
static constexpr double   RAD_TO_DEG      = 180.0 / M_PI;
static constexpr uint32_t FILE_MAGIC      = 0x42545241u; // "BTRA"
static constexpr uint32_t FILE_VERSION    = 1u;
static constexpr size_t   MAX_BREADCRUMBS = 200u;

// ── Persistent structs (binary file layout – never change field order) ────────

#pragma pack(push, 1)
struct LocationRecord {
    double  latitude;
    double  longitude;
    int64_t timestamp; // ms since epoch
};

struct FileHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t count;  // number of breadcrumb records that follow
};
#pragma pack(pop)

// ── Global state protected by g_mutex ─────────────────────────────────────────
// This library is loaded once per process. LocationCaptureService calls JNI
// from a background thread; MainActivity MethodChannel handler runs on the
// platform (main) thread. The mutex ensures consistent state.

static std::mutex              g_mutex;
static LocationRecord          g_lastLocation  = {0.0, 0.0, 0LL};
static std::vector<LocationRecord> g_breadcrumbs;
static bool                    g_locationValid = false;

// ── Math ─────────────────────────────────────────────────────────────────────

static double haversineDistance(double lat1, double lon1,
                                double lat2, double lon2) noexcept {
    const double dLat    = (lat2 - lat1) * DEG_TO_RAD;
    const double dLon    = (lon2 - lon1) * DEG_TO_RAD;
    const double sinDLat = std::sin(dLat * 0.5);
    const double sinDLon = std::sin(dLon * 0.5);
    const double a = sinDLat * sinDLat
                   + std::cos(lat1 * DEG_TO_RAD)
                   * std::cos(lat2 * DEG_TO_RAD)
                   * sinDLon * sinDLon;
    return EARTH_RADIUS_M * 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
}

static double calculateBearing(double lat1, double lon1,
                                double lat2, double lon2) noexcept {
    const double dLon    = (lon2 - lon1) * DEG_TO_RAD;
    const double lat1Rad = lat1 * DEG_TO_RAD;
    const double lat2Rad = lat2 * DEG_TO_RAD;
    const double x       = std::sin(dLon) * std::cos(lat2Rad);
    const double y       = std::cos(lat1Rad) * std::sin(lat2Rad)
                         - std::sin(lat1Rad) * std::cos(lat2Rad) * std::cos(dLon);
    double bearing = std::atan2(x, y) * RAD_TO_DEG;
    if (bearing < 0.0) bearing += 360.0;
    return bearing;
}

// ── Binary I/O (caller must hold g_mutex) ─────────────────────────────────────

static void saveToFileLocked(const char* path) {
    FILE* fp = std::fopen(path, "wb");
    if (!fp) { LOGE("Cannot write: %s", path); return; }

    const uint32_t count = static_cast<uint32_t>(g_breadcrumbs.size());
    FileHeader header{FILE_MAGIC, FILE_VERSION, count};
    std::fwrite(&header,           sizeof(FileHeader),    1,     fp);
    if (count > 0) {
        std::fwrite(g_breadcrumbs.data(), sizeof(LocationRecord), count, fp);
    }
    std::fwrite(&g_lastLocation,   sizeof(LocationRecord), 1,    fp);
    std::fwrite(&g_locationValid,  sizeof(bool),           1,    fp);
    std::fclose(fp);
}

static bool loadFromFileLocked(const char* path) {
    FILE* fp = std::fopen(path, "rb");
    if (!fp) return false;

    FileHeader header{};
    if (std::fread(&header, sizeof(FileHeader), 1, fp) != 1) {
        std::fclose(fp); return false;
    }
    if (header.magic != FILE_MAGIC || header.version != FILE_VERSION) {
        LOGE("Bad file header in %s", path);
        std::fclose(fp); return false;
    }

    g_breadcrumbs.clear();
    if (header.count > 0) {
        const uint32_t safe = (header.count < MAX_BREADCRUMBS)
                            ? header.count
                            : static_cast<uint32_t>(MAX_BREADCRUMBS);
        g_breadcrumbs.resize(safe);
        if (std::fread(g_breadcrumbs.data(), sizeof(LocationRecord), safe, fp) != safe) {
            g_breadcrumbs.clear(); std::fclose(fp); return false;
        }
        // Skip any excess records from an older build with higher cap
        if (header.count > safe) {
            std::fseek(fp, static_cast<long>(
                (header.count - safe) * sizeof(LocationRecord)), SEEK_CUR);
        }
    }

    if (std::fread(&g_lastLocation,  sizeof(LocationRecord), 1, fp) != 1) {
        std::fclose(fp); return false;
    }
    bool valid = false;
    if (std::fread(&valid, sizeof(bool), 1, fp) != 1) {
        std::fclose(fp); return false;
    }
    g_locationValid = valid;
    std::fclose(fp);
    return true;
}

// ── JNI helper ────────────────────────────────────────────────────────────────

static std::string jstringToStd(JNIEnv* env, jstring jstr) {
    if (!jstr) return {};
    const char* chars = env->GetStringUTFChars(jstr, nullptr);
    std::string result(chars);
    env->ReleaseStringUTFChars(jstr, chars);
    return result;
}

static jdoubleArray makeLocationArray(JNIEnv* env) {
    jdoubleArray arr = env->NewDoubleArray(3);
    jdouble buf[3] = {
        g_locationValid ? g_lastLocation.latitude  : 0.0,
        g_locationValid ? g_lastLocation.longitude : 0.0,
        g_locationValid ? static_cast<double>(g_lastLocation.timestamp) : 0.0
    };
    env->SetDoubleArrayRegion(arr, 0, 3, buf);
    return arr;
}

// ── JNI exports — class: com.example.bt_tracker.TrackerPlugin ─────────────────
// All functions exported under TrackerPlugin so LocationCaptureService can call
// them directly without involving MainActivity.

extern "C" {

JNIEXPORT void JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeSaveLastLocation(
        JNIEnv* env, jclass /*clazz*/,
        jdouble lat, jdouble lon, jlong timestamp, jstring jFilePath) {

    const std::string path = jstringToStd(env, jFilePath);

    std::lock_guard<std::mutex> lock(g_mutex);

    g_lastLocation  = {lat, lon, static_cast<int64_t>(timestamp)};
    g_locationValid = true;

    if (g_breadcrumbs.size() >= MAX_BREADCRUMBS) {
        g_breadcrumbs.erase(g_breadcrumbs.begin());
    }
    g_breadcrumbs.push_back(g_lastLocation);

    if (!path.empty()) saveToFileLocked(path.c_str());

    LOGI("Saved: %.6f, %.6f @ %lld", lat, lon,
         static_cast<long long>(timestamp));
}

JNIEXPORT jdoubleArray JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeLoadLastLocation(
        JNIEnv* env, jclass /*clazz*/, jstring jFilePath) {

    const std::string path = jstringToStd(env, jFilePath);

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!path.empty()) loadFromFileLocked(path.c_str());
    return makeLocationArray(env);
}

JNIEXPORT jdoubleArray JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeGetLastLocation(
        JNIEnv* env, jclass /*clazz*/) {

    std::lock_guard<std::mutex> lock(g_mutex);
    return makeLocationArray(env);
}

JNIEXPORT jdouble JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeGetDistance(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jdouble lat1, jdouble lon1, jdouble lat2, jdouble lon2) {
    return haversineDistance(lat1, lon1, lat2, lon2);
}

JNIEXPORT jdouble JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeGetBearing(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jdouble lat1, jdouble lon1, jdouble lat2, jdouble lon2) {
    return calculateBearing(lat1, lon1, lat2, lon2);
}

JNIEXPORT void JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeClearBreadcrumbs(
        JNIEnv* env, jclass /*clazz*/, jstring jFilePath) {

    const std::string path = jstringToStd(env, jFilePath);

    std::lock_guard<std::mutex> lock(g_mutex);
    g_breadcrumbs.clear();
    g_lastLocation  = {0.0, 0.0, 0LL};
    g_locationValid = false;
    if (!path.empty()) saveToFileLocked(path.c_str());
}

JNIEXPORT jint JNICALL
Java_com_example_bt_1tracker_TrackerPlugin_nativeGetBreadcrumbCount(
        JNIEnv* /*env*/, jclass /*clazz*/) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return static_cast<jint>(g_breadcrumbs.size());
}

} // extern "C"
