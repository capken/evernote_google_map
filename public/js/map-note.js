
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

var map, geocoder, marker;
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
    animation: google.maps.Animation.DROP
  });
  $('#address').keydown(function(event) {
    if(event.keyCode == 13) {
      search();
    }
  });
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
  var lat = center.nb;
  var lng = center.ob;
  return window.location.origin + 
    "?center=" + lat + "," + lng + "&zoom=" + zoom;
}

function updateMap(center) {
  map.setCenter(center);
  marker.setPosition(map.getCenter());
  //marker.setAnimation(google.maps.Animation.DROP);
}

function search() {
  var address = addInput.value;
  if(address.trim() !== "") {
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
    lat: center.nb,
    lng: center.ob
  }

  updateUI("loading");

  if(selectedNote == null) {
    var noteName = $("#new-note-name").val();
    data.note_name = encodeURIComponent(noteName);

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
