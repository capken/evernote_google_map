
var init = {
  lat: 39.908715,
  lng: 116.3973889,
  zoom: function() {
    var match = location.href.match(/zoom=(\d+)/);
    return match != null ? parseInt(match[1]) : 14
  },
  center: function() {
    var match = location.href.match(/center=([\d.]+),([\d.]+)/);
    if(match != null) {
      return new google.maps.LatLng(
        parseFloat(match[1]), parseFloat(match[2]));
    } else {
      return new google.maps.LatLng(init.lat, init.lng);
    }
  }
};

var map, geocoder, marker, clippedArea;
var mapDiv, addInput;
var selectedNote = null;

var uiState = {
  "loading" : {
    "load-icon" : true
  },
  "selection" : {
    "notes" : true,
    "save-button" : true
  },
  "success" : {
    "success-message" : true
  },
  "error" : {
    "error-message" : true
  },
}

function initialize() {
  var options = {
    center: init.center(),
    zoom: init.zoom()
  };

  mapDiv = document.getElementById("map-canvas");
  addInput = document.getElementById("address");

  map = new google.maps.Map(mapDiv, options);
  geocoder = new google.maps.Geocoder();
  marker = new google.maps.Marker({ 
    map: map,
    draggable: true,
    animation: google.maps.Animation.DROP,
    position: init.center()
  });

  initClippedArea();

  $('#address').keydown(function(event) {
    if(event.keyCode == 13) {
      search();
    }
  });
}

function initClippedArea() {
  clippedArea = new google.maps.Rectangle();

  google.maps.event.addListenerOnce(map, 'idle', function() {
    clippedArea.setOptions(rectOptions());
  });

  google.maps.event.addListener(map, 'zoom_changed', function() {
    clippedArea.setOptions(rectOptions());
  });

  google.maps.event.addListener(map, 'center_changed', function() {
    clippedArea.setOptions(rectOptions());
  });

  google.maps.event.addListener(clippedArea, 'mousemove', function(event) {
    var lat = event.latLng.lat();
    var lng = event.latLng.lng();
    //map.setOptions({ draggableCursor: 'crosshair' });
  });
}

function rectOptions() {
  return {
    strokeOpacity: 0,
    fillColor: '#FF0000',
    fillOpacity: 0.15,
    map: map,
    bounds: clippedBounds()
  }
}

function clippedBounds() {
  var proj = map.getProjection();
  var center = proj.fromLatLngToPoint(map.getCenter());

  var scale = Math.pow(2, map.getZoom());
  var tl = new google.maps.Point(
    center.x - 300/scale,
    center.y - 225/scale);
  var br = new google.maps.Point(
    center.x + 300/scale,
    center.y + 225/scale);

  return new google.maps.LatLngBounds(
    proj.fromPointToLatLng(tl),
    proj.fromPointToLatLng(br)
  );
}

function updateUI(state) {
  var allElements = ["notes", "save-button", "load-icon",
    "success-message", "error-message"];
  var meta = uiState[state];
  for(var i = 0; i < allElements.length; i++) {
    var id = allElements[i];
    if(meta[id] === true) {
      $("#" + id).show();
    } else {
      $("#" + id).hide();
    }
  }
}

function getBackURL() {
  var center = map.getCenter();
  var zoom = map.getZoom();
  var lat = center.lat();
  var lng = center.lng();
  return window.location.origin + 
    "?center=" + lat + "," + lng + "&zoom=" + zoom;
}

function updateMap(center) {
  map.setCenter(center);
  marker.setAnimation(google.maps.Animation.DROP);
  marker.setPosition(map.getCenter());
}

function search() {
  var address = addInput.value;
  address = address.replace(/^\s+|\s+$/g, '');
  if(address !== "") {
    geocoder.geocode( { "address": address }, function(data, status) {
      if(status == google.maps.GeocoderStatus.OK) {
        var loc = data[0].geometry.location;
        updateMap(loc);
      } else {
        alert("Location not found!");
      }
    });
  }
}

function popupSaveDialog() {
  updateUI("loading");

  $("#myModal").modal("show");

  $.ajax({
    url: "/api/notes",
    dataType: "json"
  })
  .done(function(data) {
    var notes = data.notes;
    var htmlCodes = [];

    for(var i = 0; i < notes.length; i++) {
      var note = notes[i];
      htmlCodes.push('<a href="#" onclick="javascript:selectNote(this)" class="list-group-item" id="' + note.guid + '">' + 
        note.title + '</a>');
    }

    $("#note-list").html(htmlCodes.join(""));
    updateUI("selection");
  })
  .fail(function(xhr) {
    if(xhr.status == 401) {
      window.location.href = "oauth/request_token?back_url=" + 
        encodeURIComponent(getBackURL());
    } else {
      updateUI("error");
    }
  });
}

function selectNote(note) {
  if(selectedNote != note) {
    if(selectedNote != null) {
      selectedNote.classList.remove("active");
    }
    selectedNote = note;
    selectedNote.classList.add("active");
  }
}

function resetSelectedNote() {
  if(selectedNote != null) {
    selectedNote.classList.remove("active");
    selectedNote = null;
  }
}

function save() {
  var center = map.getCenter();
  var data = {
    zoom: map.getZoom(),
    lat: center.lat(),
    lng: center.lng()
  }

  var mp = marker.getPosition();
  if(typeof mp !== "undefined") {
    data["mlat"] = mp.lat();
    data["mlng"] = mp.lng();
  }

  updateUI("loading");

  if(selectedNote == null) {
    var noteName = $("#new-note-name").val();
    data.note_name = noteName;

    $.ajax({
      type: "POST",
      dataType: "json",
      url: "/api/notes",
      data: data
    })
    .done(function(data) {
      updateUI("success");
      $("#note-link").attr("href", data.note_url);
    })
    .fail(function(xhr) {
      updateUI("error");
    });
  } else {
    $.ajax({
      type: "PUT",
      dataType: "json",
      url: "/api/notes/" + selectedNote.id,
      data: data
    })
    .done(function(data){
      updateUI("success");
      $("#note-link").attr("href", data.note_url);
    })
    .fail(function(xhr){
      updateUI("error");
    });
  }
}

function moveMarker() {
  updateMap(map.getCenter());
}

function shareLink(link) {
  window.open(link.href, '',
    'menubar=no,toolbar=no,resizable=yes,scrollbars=yes,height=600,width=600');
}
