import Foundation

/// Sample GPX used to seed the routes list. The same file is in the app bundle for a manual import.
enum SampleGPX {
    static var data: Data {
        if let url = Bundle.main.url(forResource: "xuhui-riverside", withExtension: "gpx"),
           let file = try? Data(contentsOf: url),
           file.count > 64 {
            return file
        }
        return Data(fallback.utf8)
    }

    /// Used when the GPX resource is missing from the bundle.
    static let fallback = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Sky" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>徐汇滨江</name>
    <author>
      <name>阿宁</name>
    </author>
  </metadata>
  <trk>
    <name>徐汇滨江</name>
    <trkseg>
      <trkpt lat="31.240200" lon="121.490400">
        <ele>6.0</ele>
      </trkpt>
      <trkpt lat="31.240847" lon="121.490363">
        <ele>7.6</ele>
      </trkpt>
      <trkpt lat="31.241488" lon="121.490251">
        <ele>9.2</ele>
      </trkpt>
      <trkpt lat="31.242116" lon="121.490067">
        <ele>10.9</ele>
      </trkpt>
      <trkpt lat="31.242725" lon="121.489811">
        <ele>12.5</ele>
      </trkpt>
      <trkpt lat="31.243309" lon="121.489487">
        <ele>14.1</ele>
      </trkpt>
      <trkpt lat="31.243862" lon="121.489097">
        <ele>15.7</ele>
      </trkpt>
      <trkpt lat="31.244378" lon="121.488645">
        <ele>17.4</ele>
      </trkpt>
      <trkpt lat="31.244853" lon="121.488137">
        <ele>19.0</ele>
      </trkpt>
      <trkpt lat="31.245282" lon="121.487576">
        <ele>20.6</ele>
      </trkpt>
      <trkpt lat="31.245660" lon="121.486969">
        <ele>22.2</ele>
      </trkpt>
      <trkpt lat="31.245984" lon="121.486322">
        <ele>23.8</ele>
      </trkpt>
      <trkpt lat="31.246251" lon="121.485640">
        <ele>25.5</ele>
      </trkpt>
      <trkpt lat="31.246457" lon="121.484931">
        <ele>27.1</ele>
      </trkpt>
      <trkpt lat="31.246601" lon="121.484202">
        <ele>28.7</ele>
      </trkpt>
      <trkpt lat="31.246682" lon="121.483460">
        <ele>30.3</ele>
      </trkpt>
      <trkpt lat="31.246698" lon="121.482713">
        <ele>32.0</ele>
      </trkpt>
      <trkpt lat="31.246650" lon="121.481967">
        <ele>33.6</ele>
      </trkpt>
      <trkpt lat="31.246537" lon="121.481231">
        <ele>35.2</ele>
      </trkpt>
      <trkpt lat="31.246362" lon="121.480511">
        <ele>36.8</ele>
      </trkpt>
      <trkpt lat="31.246125" lon="121.479815">
        <ele>38.5</ele>
      </trkpt>
      <trkpt lat="31.245829" lon="121.479150">
        <ele>40.1</ele>
      </trkpt>
      <trkpt lat="31.245478" lon="121.478522">
        <ele>41.7</ele>
      </trkpt>
      <trkpt lat="31.245074" lon="121.477937">
        <ele>43.3</ele>
      </trkpt>
      <trkpt lat="31.244621" lon="121.477402">
        <ele>44.9</ele>
      </trkpt>
      <trkpt lat="31.244125" lon="121.476922">
        <ele>46.6</ele>
      </trkpt>
      <trkpt lat="31.243589" lon="121.476500">
        <ele>48.2</ele>
      </trkpt>
      <trkpt lat="31.243020" lon="121.476143">
        <ele>49.8</ele>
      </trkpt>
      <trkpt lat="31.242423" lon="121.475852">
        <ele>51.4</ele>
      </trkpt>
      <trkpt lat="31.241804" lon="121.475632">
        <ele>50.8</ele>
      </trkpt>
      <trkpt lat="31.241169" lon="121.475484">
        <ele>49.0</ele>
      </trkpt>
      <trkpt lat="31.240524" lon="121.475409">
        <ele>47.2</ele>
      </trkpt>
      <trkpt lat="31.239876" lon="121.475409">
        <ele>45.4</ele>
      </trkpt>
      <trkpt lat="31.239231" lon="121.475484">
        <ele>43.6</ele>
      </trkpt>
      <trkpt lat="31.238596" lon="121.475632">
        <ele>41.8</ele>
      </trkpt>
      <trkpt lat="31.237977" lon="121.475852">
        <ele>40.0</ele>
      </trkpt>
      <trkpt lat="31.237380" lon="121.476143">
        <ele>38.2</ele>
      </trkpt>
      <trkpt lat="31.236811" lon="121.476500">
        <ele>36.4</ele>
      </trkpt>
      <trkpt lat="31.236275" lon="121.476922">
        <ele>34.6</ele>
      </trkpt>
      <trkpt lat="31.235779" lon="121.477402">
        <ele>32.8</ele>
      </trkpt>
      <trkpt lat="31.235326" lon="121.477937">
        <ele>31.0</ele>
      </trkpt>
      <trkpt lat="31.234922" lon="121.478522">
        <ele>29.2</ele>
      </trkpt>
      <trkpt lat="31.234571" lon="121.479150">
        <ele>27.4</ele>
      </trkpt>
      <trkpt lat="31.234275" lon="121.479815">
        <ele>25.6</ele>
      </trkpt>
      <trkpt lat="31.234038" lon="121.480511">
        <ele>23.8</ele>
      </trkpt>
      <trkpt lat="31.233863" lon="121.481231">
        <ele>22.0</ele>
      </trkpt>
      <trkpt lat="31.233750" lon="121.481967">
        <ele>20.2</ele>
      </trkpt>
      <trkpt lat="31.233702" lon="121.482713">
        <ele>18.4</ele>
      </trkpt>
      <trkpt lat="31.233718" lon="121.483460">
        <ele>17.5</ele>
      </trkpt>
      <trkpt lat="31.233799" lon="121.484202">
        <ele>16.9</ele>
      </trkpt>
      <trkpt lat="31.233943" lon="121.484931">
        <ele>16.3</ele>
      </trkpt>
      <trkpt lat="31.234149" lon="121.485640">
        <ele>15.6</ele>
      </trkpt>
      <trkpt lat="31.234416" lon="121.486322">
        <ele>15.0</ele>
      </trkpt>
      <trkpt lat="31.234740" lon="121.486969">
        <ele>14.3</ele>
      </trkpt>
      <trkpt lat="31.235118" lon="121.487576">
        <ele>13.7</ele>
      </trkpt>
      <trkpt lat="31.235547" lon="121.488137">
        <ele>13.1</ele>
      </trkpt>
      <trkpt lat="31.236022" lon="121.488645">
        <ele>12.4</ele>
      </trkpt>
      <trkpt lat="31.236538" lon="121.489097">
        <ele>11.8</ele>
      </trkpt>
      <trkpt lat="31.237091" lon="121.489487">
        <ele>11.2</ele>
      </trkpt>
      <trkpt lat="31.237675" lon="121.489811">
        <ele>10.5</ele>
      </trkpt>
      <trkpt lat="31.238284" lon="121.490067">
        <ele>9.9</ele>
      </trkpt>
      <trkpt lat="31.238912" lon="121.490251">
        <ele>9.3</ele>
      </trkpt>
      <trkpt lat="31.239553" lon="121.490363">
        <ele>8.6</ele>
      </trkpt>
      <trkpt lat="31.240200" lon="121.490400">
        <ele>6.0</ele>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
"""
}
