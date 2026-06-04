package com.fazakis.opencallcompanion;

import org.json.JSONArray;
import java.util.Collection;

final class JsonUtil {
    private JsonUtil() {}

    static JSONArray array(Collection<String> values) {
        JSONArray arr = new JSONArray();
        for (String value : values) arr.put(value);
        return arr;
    }
}
